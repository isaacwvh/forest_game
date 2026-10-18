import SwiftUI
import RealityKit
import Combine
import UIKit

@MainActor
protocol GardenRenderer: AnyObject {
    var view: ARView { get }
    func display(_ garden: GardenSnapshot, catalog: any AssetCatalogProviding)
    func resetCamera()
    func setActive(_ active: Bool)
    func stop()
}

struct PlantRenderDiagnostic: Identifiable {
    let id: UUID
    let label: String
    let orientation: String
    let animationCount: Int
    let bounds: SIMD3<Float>
    let minimumY: Float
}

@MainActor
final class RealityGardenRenderer: NSObject, ObservableObject, GardenRenderer, UIGestureRecognizerDelegate {
    let view: ARView
    @Published private(set) var isLoading = false
    @Published private(set) var loadedCount = 0
    @Published private(set) var errors: [String] = []
    @Published private(set) var diagnostics: [PlantRenderDiagnostic] = []
    @Published private(set) var sceneUpdateMilliseconds: Double = 0
    @Published private(set) var loadSeconds: Double = 0
    @Published private(set) var lastGroundPoint: SIMD2<Double>?
    @Published var selectedPlantID: UUID? { didSet { updateSelection() } }
    var onSelect: ((UUID?) -> Void)?

    private let root = AnchorEntity(world: .zero)
    private let rig = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private let loader = PlantModelLoader()
    private var snapshot: GardenSnapshot?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var placements: [UUID: Entity] = [:]
    private var playbacks: [AnimationPlaybackController] = []
    private var updateSubscription: Cancellable?
    private var selectionMarker: Entity?
    private var debugGeometry: Entity?
    private var isActive = true
    private var wantsMotion = true
    private var groundPicking = false
    private var showBounds = false
    private var yaw: Float = .pi / 4
    private var elevation: Float = 0.65
    private var distance: Float = 21
    private var target = SIMD3<Float>(5, 1, 5)
    private var frameTime: Double = 0
    private var frameCount = 0

    override init() {
        view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        super.init()
        view.environment.background = .color(UIColor(red: 0.90, green: 0.93, blue: 0.89, alpha: 1))
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.scene.addAnchor(root)
        view.scene.addAnchor(rig)
        camera.camera.fieldOfViewInDegrees = 42
        rig.addChild(camera)
        let sun = DirectionalLight()
        sun.light.color = UIColor(red: 1, green: 0.95, blue: 0.85, alpha: 1)
        sun.light.intensity = 1700
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 50, depthBias: 2)
        sun.look(at: [5, 0, 5], from: [-5, 14, 10], relativeTo: nil)
        rig.addChild(sun)
        let fill = DirectionalLight()
        fill.light.color = UIColor(red: 0.82, green: 0.90, blue: 1, alpha: 1)
        fill.light.intensity = 650
        fill.look(at: [5, 0, 5], from: [12, 8, -4], relativeTo: nil)
        rig.addChild(fill)
        configureGestures()
        updateCamera()
        subscribeToUpdates()
    }

    private func subscribeToUpdates() {
        guard updateSubscription == nil else { return }
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            // RealityKit scene updates are delivered on the main thread.
            self?.recordFrame(event.deltaTime)
        }
    }

    func display(_ garden: GardenSnapshot, catalog: any AssetCatalogProviding) {
        subscribeToUpdates()
        guard snapshot != garden else { return }
        let dimensionsChanged = snapshot?.width != garden.width || snapshot?.depth != garden.depth
        snapshot = garden
        loadTask?.cancel()
        generation = UUID()
        let token = generation
        // Start after SwiftUI's update pass; publishing synchronously there is invalid.
        loadTask = Task { [weak self] in
            guard let self = self else { return }
            self.isLoading = true
            self.errors = []
            self.diagnostics = []
            self.loadedCount = 0
            self.loadSeconds = 0
            let start = Date()
            self.playbacks.forEach { $0.stop() }
            self.playbacks.removeAll()
            self.placements.removeAll()
            for child in Array(self.root.children) { child.removeFromParent() }
            self.selectionMarker = nil
            self.debugGeometry = nil
            self.makeBoard(garden)
            if dimensionsChanged { self.resetCamera() }
            for plant in garden.plants {
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    let asset = try catalog.resolve(plant)
                    let model = try await self.loader.load(asset)
                    guard !Task.isCancelled, self.generation == token else { return }
                    let placement = Entity()
                    placement.name = plant.id.uuidString
                    placement.position = GardenCoordinates.world(x: plant.x, y: plant.y, unitMetres: garden.gardenUnitMetres)
                    placement.orientation = simd_quatf(angle: Float(plant.rotationDegrees) * .pi / 180, axis: [0, 1, 0])
                    // USD model dimensions are metres; gardenUnitMetres converts ground coordinates only.
                    placement.addChild(model.entity)
                    self.root.addChild(placement)
                    self.placements[plant.id] = placement
                    let bounds = model.entity.visualBounds(relativeTo: placement)
                    let proxy = Entity()
                    proxy.name = "selection-proxy"
                    proxy.position = bounds.center
                    let size = simd_max(bounds.extents, SIMD3<Float>(repeating: 0.15))
                    proxy.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
                    placement.addChild(proxy)
                    let clips = self.playWind(in: model.entity)
                    self.diagnostics.append(PlantRenderDiagnostic(id: plant.id,
                        label: "\(plant.speciesId) · \(plant.growthStage.rawValue) · \(plant.variantId)",
                        orientation: model.orientationNote, animationCount: clips,
                        bounds: bounds.extents, minimumY: bounds.min.y))
                    if clips == 0 { self.errors.append("\(asset.asset.file): no playable wind animation was imported.") }
                    self.loadedCount += 1
                } catch is CancellationError { return }
                catch { self.errors.append("\(plant.speciesId) \(plant.growthStage.title): \(error.localizedDescription)") }
            }
            guard self.generation == token else { return }
            self.isLoading = false
            self.loadSeconds = Date().timeIntervalSince(start)
            self.applyMotion()
            self.updateSelection()
            self.updateDebugGeometry()
        }
    }

    func retry(_ garden: GardenSnapshot, catalog: any AssetCatalogProviding) {
        snapshot = nil
        loader.clear()
        display(garden, catalog: catalog)
    }

    private func makeBoard(_ garden: GardenSnapshot) {
        let width = Float(garden.width * garden.gardenUnitMetres)
        let depth = Float(garden.depth * garden.gardenUnitMetres)
        let board = ModelEntity(mesh: .generateBox(size: [width, 0.22, depth], cornerRadius: 0.10),
                                materials: [SimpleMaterial(color: UIColor(red: 0.45, green: 0.57, blue: 0.36, alpha: 1), roughness: 1, isMetallic: false)])
        board.name = "temporary-shared-board"
        board.position = [width / 2, -0.11, depth / 2]
        root.addChild(board)
    }

    private func playWind(in entity: Entity) -> Int {
        // A root clip often contains tracks for its descendants; don't play those twice.
        if let clip = entity.availableAnimations.first {
            let controller = entity.playAnimation(clip.repeat(duration: .infinity), transitionDuration: 0,
                                                  startsPaused: !wantsMotion || !isActive)
            playbacks.append(controller)
            return 1
        }
        return entity.children.reduce(0) { $0 + playWind(in: $1) }
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard wantsMotion != enabled else { return }
        wantsMotion = enabled
        applyMotion()
    }
    private func applyMotion() {
        for controller in playbacks {
            if wantsMotion && isActive { controller.resume() } else { controller.pause() }
        }
    }
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        view.isHidden = !active
        frameTime = 0
        frameCount = 0
        applyMotion()
    }
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        playbacks.forEach { $0.stop() }
        playbacks.removeAll()
        updateSubscription?.cancel()
        updateSubscription = nil
        snapshot = nil
        isActive = false
        view.isHidden = true
    }

    func resetCamera() {
        guard let garden = snapshot else { return }
        target = [Float(garden.width * garden.gardenUnitMetres / 2), 1,
                  Float(garden.depth * garden.gardenUnitMetres / 2)]
        distance = Float(max(garden.width, garden.depth) * garden.gardenUnitMetres) * 2.25
        yaw = .pi / 4
        elevation = 0.65
        updateCamera()
    }
    func zoom(by factor: Float) { distance = min(max(distance * factor, 4), 60); updateCamera() }
    private func updateCamera() {
        let offset = SIMD3<Float>(sin(yaw) * cos(elevation), sin(elevation), cos(yaw) * cos(elevation)) * distance
        camera.look(at: target, from: target + offset, relativeTo: nil)
    }

    func setDebugOptions(bounds: Bool, groundPicking: Bool) {
        self.groundPicking = groundPicking
        if showBounds != bounds { showBounds = bounds; updateDebugGeometry() }
    }

    private func updateSelection() {
        selectionMarker?.removeFromParent()
        guard let id = selectedPlantID, let placement = placements[id] else { return }
        // Selection marker only, never a gameplay clearance ring.
        let marker = ModelEntity(mesh: .generateBox(size: [0.36, 0.025, 0.36], cornerRadius: 0.01),
                                 materials: [UnlitMaterial(color: UIColor.systemYellow)])
        marker.position = placement.position + [0, 0.025, 0]
        root.addChild(marker)
        selectionMarker = marker
    }

    private func updateDebugGeometry() {
        debugGeometry?.removeFromParent()
        guard showBounds else { return }
        let container = Entity()
        for diagnostic in diagnostics {
            guard let placement = placements[diagnostic.id] else { continue }
            let bounds = placement.visualBounds(relativeTo: placement)
            let size = bounds.extents
            let guideFrame = Entity()
            guideFrame.transform = placement.transform
            container.addChild(guideFrame)
            for x in [-Float(1), Float(1)] {
                for z in [-Float(1), Float(1)] {
                    let line = ModelEntity(mesh: .generateBox(size: [0.018, max(size.y, 0.02), 0.018]),
                                           materials: [UnlitMaterial(color: .systemOrange)])
                    line.position = bounds.center + [x * size.x / 2, 0, z * size.z / 2]
                    guideFrame.addChild(line)
                }
            }
        }
        root.addChild(container)
        debugGeometry = container
    }

    private func recordFrame(_ delta: TimeInterval) {
        guard isActive, delta > 0, delta < 1 else { return }
        frameTime += delta
        frameCount += 1
        if frameTime >= 1 {
            sceneUpdateMilliseconds = frameTime / Double(frameCount) * 1000
            frameTime = 0
            frameCount = 0
        }
    }

    private func configureGestures() {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbitGesture(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panGesture(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchGesture(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapGesture(_:)))
        tap.require(toFail: orbit)
        for gesture in [orbit, pan, pinch, tap] { gesture.delegate = self; view.addGestureRecognizer(gesture) }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer) ||
        (otherGestureRecognizer is UIPinchGestureRecognizer && gestureRecognizer is UIPanGestureRecognizer)
    }
    @objc private func orbitGesture(_ gesture: UIPanGestureRecognizer) {
        let change = gesture.translation(in: view)
        yaw -= Float(change.x) * 0.007
        elevation = min(max(elevation + Float(change.y) * 0.005, 0.25), 1.35)
        gesture.setTranslation(.zero, in: view)
        updateCamera()
    }
    @objc private func panGesture(_ gesture: UIPanGestureRecognizer) {
        let change = gesture.translation(in: view)
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        target += (-right * Float(change.x) - forward * Float(change.y)) * distance * 0.0015
        if let garden = snapshot {
            target.x = min(max(target.x, 0), Float(garden.width * garden.gardenUnitMetres))
            target.z = min(max(target.z, 0), Float(garden.depth * garden.gardenUnitMetres))
        }
        gesture.setTranslation(.zero, in: view)
        updateCamera()
    }
    @objc private func pinchGesture(_ gesture: UIPinchGestureRecognizer) {
        zoom(by: 1 / Float(max(gesture.scale, 0.01)))
        gesture.scale = 1
    }
    @objc private func tapGesture(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        if groundPicking, let garden = snapshot, let ray = view.ray(through: point) {
            lastGroundPoint = GardenCoordinates.groundIntersection(origin: ray.origin, direction: ray.direction,
                width: garden.width, depth: garden.depth, unitMetres: garden.gardenUnitMetres)
            return
        }
        var candidate = view.entity(at: point)
        while let entity = candidate {
            if let id = UUID(uuidString: entity.name), placements[id] != nil {
                selectedPlantID = id
                onSelect?(id)
                return
            }
            candidate = entity.parent
        }
        selectedPlantID = nil
        onSelect?(nil)
    }
}

struct GardenSceneView: UIViewRepresentable {
    let renderer: RealityGardenRenderer
    let garden: GardenSnapshot
    let catalog: any AssetCatalogProviding
    var motionEnabled = true
    var active = true
    var showBounds = false
    var groundPicking = false

    func makeUIView(context: Context) -> ARView { renderer.view }
    func updateUIView(_ uiView: ARView, context: Context) {
        renderer.display(garden, catalog: catalog)
        renderer.setMotionEnabled(motionEnabled)
        renderer.setActive(active)
        renderer.setDebugOptions(bounds: showBounds, groundPicking: groundPicking)
    }
}
