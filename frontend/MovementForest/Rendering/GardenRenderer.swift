import SwiftUI
import RealityKit
import Combine
import UIKit

/// SwiftUI owns this session. Its destruction schedules terminal cleanup even if
/// a renderer is temporarily retained by a model import or a UIKit callback.
@MainActor
final class GardenRenderSession: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let renderer = RealityGardenRenderer()
    private var updates: AnyCancellable?
    init() {
        updates = renderer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    deinit {
        let retired = renderer
        Task { @MainActor in retired.stop() }
    }
}

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
    let speciesId: String
    let label: String
    let orientation: String
    let animationCount: Int
    let bounds: SIMD3<Float>
    let minimumY: Float
}

enum GardenDragPhase: Equatable { case began, changed, ended, cancelled }

@MainActor
private final class GardenAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

enum GardenCameraAction: String, CaseIterable {
    case zoomIn = "Zoom in", zoomOut = "Zoom out", reset = "Reset garden view"
    case orbitLeft = "Orbit left", orbitRight = "Orbit right", tiltUp = "Tilt up", tiltDown = "Tilt down"
    case panLeft = "Pan left", panRight = "Pan right", panForward = "Pan forward", panBack = "Pan back"
}

struct EditorRenderPreview: Equatable {
    var plant: GardenPlant
    var radius: Double?
    var valid: Bool
    var adult: Bool
    var movable: Bool
}

@MainActor
final class RealityGardenRenderer: NSObject, ObservableObject, GardenRenderer, UIGestureRecognizerDelegate {
    private let diagnosticID = UUID()
    private var disposed = false
    private var visitorGeneration = UUID()
    let view: ARView
    @Published private(set) var isLoading = false
    @Published private(set) var loadedCount = 0
    @Published private(set) var errors: [String] = []
    @Published private(set) var diagnostics: [PlantRenderDiagnostic] = []
    @Published private(set) var sceneUpdateMilliseconds: Double = 0
    @Published private(set) var loadSeconds: Double = 0
    @Published private(set) var modelLoadCount = 0
    @Published private(set) var lastGroundPoint: SIMD2<Double>?
    @Published private(set) var visitorAssetReady = false
    @Published private(set) var visitorAssetIssue: String?
    @Published var selectedPlantID: UUID? { didSet { updateSelection() } }
    var onSelect: ((UUID?) -> Void)?
    var onGroundDrag: ((SIMD2<Double>?, GardenDragPhase) -> Void)?

    private let root = AnchorEntity(world: .zero)
    private let rig = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private let loader = PlantModelLoader()
    private let visitorModels: VisitorModelLibrary
    private let visitorRoot = AnchorEntity(world: .zero)
    private weak var visitorStore: VisitorCoordinator?
    private var visitorTemplate: Entity?
    private var visitorLoadTask: Task<Void, Never>?
    private var visitorEntities: [UUID: Entity] = [:]
    private var overlayFrames: [CGRect] = []
    private var visitorAccessibility: [UUID: GardenAccessibilityElement] = [:]
    private var accessibilityIDs: [UUID]?
    private var cameraAccessibility: UIAccessibilityElement?
    private var visitorPlaybacks: [UUID: [AnimationPlaybackController]] = [:]
    private var snapshot: GardenSnapshot?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var needsAssetReload = false
    private var placements: [UUID: Entity] = [:]
    private var plantPlaybacks: [UUID: [AnimationPlaybackController]] = [:]
    private var renderedPlants: [UUID: GardenPlant] = [:]
    private struct PreparedVisual {
        let plant: GardenPlant
        let model: PlantModelLoader.LoadedModel
        let assetFile: String
    }
    private var preparedVisuals: [UUID: PreparedVisual] = [:]
    private let sharedEffects = SharedGardenEffects()
    private var growthEffects: GardenEffectsCoordinator?
    private var growthUpdates: AnyCancellable?
    var preparedGrowthCount: Int { preparedVisuals.count }
    private var board: Entity?
    private var preview: EditorRenderPreview?
    private var previewAnchor: Entity?
    private var clearanceGuide: Entity?
    private var guideStyle: String?
    private var previewTask: Task<Void, Never>?
    private var previewKey: String?
    private var dragOffset: SIMD2<Double>?
    private var dragging = false
    private var oneFingerMovesPlant: Bool?
    private var playbacks: [AnimationPlaybackController] { plantPlaybacks.values.flatMap { $0 } }
    private var updateSubscription: Cancellable?
    private var selectionMarker: Entity?
    private var debugGeometry: Entity?
    private var isActive = false
    private var wantsMotion = true
    private var groundPicking = false
    private var showBounds = false
    private var yaw: Float = .pi / 4
    private var elevation: Float = 0.65
    private var distance: Float = 21
    private var target = SIMD3<Float>(5, 1, 5)
    private var frameTime: Double = 0
    private var frameCount = 0

    override convenience init() { self.init(visitorModels: VisitorModelLibrary.shared) }

    init(visitorModels: VisitorModelLibrary) {
        self.visitorModels = visitorModels
        view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        super.init()
        view.isHidden = true
        LifecycleDiagnostics.event("renderer created id=\(diagnosticID)")
        view.environment.background = .color(UIColor(red: 0.90, green: 0.93, blue: 0.89, alpha: 1))
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.scene.addAnchor(root)
        view.scene.addAnchor(rig)
        view.scene.addAnchor(visitorRoot)
        camera.camera.fieldOfViewInDegrees = 42
        camera.name = "garden-camera"
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
        configureAccessibility()
        updateCamera()
    }

    deinit { LifecycleDiagnostics.event("renderer destroyed id=\(diagnosticID)") }

    private func subscribeToUpdates() {
        guard !disposed, isActive, updateSubscription == nil else { return }
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            // RealityKit scene updates are delivered on the main thread.
            self?.recordFrame(event.deltaTime)
        }
    }

    func display(_ garden: GardenSnapshot, catalog: any AssetCatalogProviding) {
        guard !disposed else { return }
        guard snapshot != garden || needsAssetReload else { return }
        let dimensionsChanged = snapshot?.gardenId != garden.gardenId || snapshot?.width != garden.width ||
            snapshot?.depth != garden.depth || snapshot?.gardenUnitMetres != garden.gardenUnitMetres
        let requiresLoads = dimensionsChanged || garden.plants.contains { plant in
            guard let old = renderedPlants[plant.id], placements[plant.id] != nil else { return true }
            return old.speciesId != plant.speciesId || old.variantId != plant.variantId ||
                old.assetVersion != plant.assetVersion || old.growthStage != plant.growthStage
        }
        let visualsChanged = dimensionsChanged || snapshot?.plants != garden.plants ||
            snapshot?.catalogVersion != garden.catalogVersion || needsAssetReload || (loadTask == nil && requiresLoads)
        if visualsChanged {
            if growthEffects?.holdingRecap == true { sharedEffects.cancel() }
            else { settleGrowthEffects() }
        }
        snapshot = garden
        guard visualsChanged else { return }
        needsAssetReload = false
        loadTask?.cancel()
        generation = UUID()
        let token = generation
        // Start after SwiftUI's update pass; publishing synchronously there is invalid.
        loadTask = Task { [weak self] in
            guard let self = self else { return }
            guard !Task.isCancelled, self.generation == token else { return }
            self.isLoading = requiresLoads
            if requiresLoads { self.errors = [] }
            self.loadedCount = 0
            self.loadSeconds = 0
            let start = Date()
            if dimensionsChanged {
                self.preparedVisuals = [:]
                self.playbacks.forEach { $0.stop() }
                self.plantPlaybacks.removeAll()
                self.placements.removeAll()
                self.renderedPlants.removeAll()
                self.diagnostics.removeAll()
                for child in Array(self.root.children) { child.removeFromParent() }
                self.selectionMarker = nil; self.debugGeometry = nil
                self.previewAnchor = nil; self.clearanceGuide = nil; self.guideStyle = nil; self.previewKey = nil
                self.makeBoard(garden)
            }
            let wanted = Set(garden.plants.map(\.id))
            for id in Array(self.placements.keys) where !wanted.contains(id) { self.removePlant(id) }
            if dimensionsChanged { self.resetCamera() }
            for plant in garden.plants {
                guard !Task.isCancelled, self.generation == token else { return }
                if let previous = self.renderedPlants[plant.id], self.placements[plant.id] != nil,
                   previous.speciesId == plant.speciesId, previous.variantId == plant.variantId,
                   previous.assetVersion == plant.assetVersion, previous.growthStage == plant.growthStage {
                    self.transform(self.placements[plant.id]!, plant: plant, garden: garden)
                    self.renderedPlants[plant.id] = plant
                    self.loadedCount += 1
                    continue
                }
                do {
                    let asset = try catalog.resolve(plant)
                    let model = try await self.loader.load(asset)
                    guard !Task.isCancelled, self.generation == token else { return }
                    let visual = PreparedVisual(plant: plant, model: model, assetFile: asset.asset.file)
                    // Preload behind the recap, keeping the old model grounded.
                    // Only receipt-backed stage growth is allowed to delay a swap.
                    if let old = self.renderedPlants[plant.id], self.placements[plant.id] != nil,
                       old.speciesId == plant.speciesId, old.variantId == plant.variantId,
                       old.assetVersion == plant.assetVersion, old.growthStage.number < plant.growthStage.number,
                       self.growthEffects?.holdingRecap == true || self.growthEffects?.targets[plant.id]?.advancesStage == true {
                        self.preparedVisuals[plant.id] = visual
                    } else { self.installVisual(visual, plant: plant, garden: garden) }
                    self.loadedCount += 1
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.errors.append("\(plant.speciesId) \(plant.growthStage.title): \(error.localizedDescription)")
                    if self.placements[plant.id] != nil { continue }
                    let placeholder = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [SimpleMaterial(color: .systemGray, isMetallic: false)])
                    placeholder.name = plant.id.uuidString
                    placeholder.generateCollisionShapes(recursive: false)
                    self.transform(placeholder, plant: plant, garden: garden)
                    self.root.addChild(placeholder); self.placements[plant.id] = placeholder
                    // Leave renderedPlants unset so a later refresh can retry the asset.
                }
            }
            guard self.generation == token else { return }
            self.isLoading = false
            self.loadSeconds = Date().timeIntervalSince(start)
            self.applyMotion()
            self.updateSelection()
            self.updateDebugGeometry()
            self.updatePreview(self.preview, catalog: catalog)
            self.loadTask = nil
            self.presentGrowthEffectsIfReady()
        }
    }

    func setGrowthEffects(_ effects: GardenEffectsCoordinator?) {
        guard growthEffects !== effects else { return }
        settleGrowthEffects(); growthUpdates?.cancel()
        growthEffects = effects
        growthUpdates = effects?.changes.sink { [weak self] _ in
            // Defer publication until after any enclosing SwiftUI update.
            Task { @MainActor [weak self] in self?.presentGrowthEffectsIfReady() }
        }
    }

    private func installVisual(_ visual: PreparedVisual, plant: GardenPlant, garden: GardenSnapshot) {
        diagnostics.removeAll { $0.id == plant.id }
        plantPlaybacks.removeValue(forKey: plant.id)?.forEach { $0.stop() }
        modelLoadCount += 1
        // Reuse the ground anchor, including its identity and yaw, across stages.
        let placement = placements[plant.id] ?? Entity()
        for child in Array(placement.children) { child.removeFromParent() }
        placement.name = plant.id.uuidString
        transform(placement, plant: plant, garden: garden)
        placement.addChild(visual.model.entity)
        if placement.parent == nil { root.addChild(placement) }
        placements[plant.id] = placement; renderedPlants[plant.id] = plant
        let bounds = visual.model.entity.visualBounds(relativeTo: placement)
        let proxy = Entity()
        proxy.name = "selection-proxy"; proxy.position = bounds.center
        let size = simd_max(bounds.extents, SIMD3<Float>(repeating: 0.15))
        proxy.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
        placement.addChild(proxy)
        let clips = playWind(in: visual.model.entity, plantID: plant.id)
        diagnostics.append(PlantRenderDiagnostic(id: plant.id, speciesId: plant.speciesId,
            label: "\(plant.speciesId) · \(plant.growthStage.rawValue) · \(plant.variantId)",
            orientation: visual.model.orientationNote, animationCount: clips, bounds: bounds.extents, minimumY: bounds.min.y))
        if clips == 0 { errors.append("\(visual.assetFile): no playable wind animation was imported.") }
    }

    @discardableResult
    private func commitPreparedVisual(_ id: UUID) -> Entity? {
        if let visual = preparedVisuals.removeValue(forKey: id), let garden = snapshot,
           let plant = garden.plants.first(where: { $0.id == id }),
           plant.speciesId == visual.plant.speciesId, plant.variantId == visual.plant.variantId,
           plant.assetVersion == visual.plant.assetVersion, plant.growthStage == visual.plant.growthStage {
            installVisual(visual, plant: plant, garden: garden)
            updateSelection()
        }
        return placements[id]
    }

    private func settleGrowthEffects() {
        sharedEffects.cancel()
        for id in Array(preparedVisuals.keys) { commitPreparedVisual(id) }
    }

    private func presentGrowthEffectsIfReady() {
        guard !disposed, let effects = growthEffects, !effects.holdingRecap,
              let garden = snapshot, loadTask == nil else { return }
        guard isActive else {
            // Quiet background/manual sync never queues a later stage celebration.
            if !effects.targets.values.contains(where: { $0.water }) {
                _ = effects.takeTargets(for: garden); settleGrowthEffects()
            }
            return
        }
        for var target in effects.takeTargets(for: garden) {
            guard let source = placements[target.id], renderedPlants[target.id] != nil else { continue }
            if preparedVisuals[target.id] == nil,
               (renderedPlants[target.id]?.growthStage.number ?? 0) < target.after.number {
                // Artwork failed: retain the saved growth and watering feedback,
                // but do not imply that a missing stage model was revealed.
                target.before = target.after
                if !target.water { continue }
            }
            let plantID = target.id
            sharedEffects.enqueue(target, source: source, parent: root, reducedMotion: !wantsMotion) { [weak self] in
                self?.commitPreparedVisual(plantID)
            }
        }
        // A non-recipient may also have a new confirmed model. Do not leave it
        // at an old stage merely because other plants are still being watered.
        let animating = sharedEffects.plantIDs
        for id in Array(preparedVisuals.keys) where !animating.contains(id) { commitPreparedVisual(id) }
    }

    func retry(_ garden: GardenSnapshot, catalog: any AssetCatalogProviding) {
        needsAssetReload = true
        renderedPlants.removeAll()
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
        self.board = board
    }

    private func transform(_ entity: Entity, plant: GardenPlant, garden: GardenSnapshot) {
        entity.position = GardenCoordinates.world(x: plant.x, y: plant.y, unitMetres: garden.gardenUnitMetres)
        entity.orientation = simd_quatf(angle: Float(plant.rotationDegrees) * .pi / 180, axis: [0, 1, 0])
    }

    private func removePlant(_ id: UUID) {
        diagnostics.removeAll { $0.id == id }
        plantPlaybacks.removeValue(forKey: id)?.forEach { $0.stop() }
        placements.removeValue(forKey: id)?.removeFromParent()
        renderedPlants.removeValue(forKey: id)
    }

    private func playWind(in entity: Entity, plantID: UUID) -> Int {
        // A root clip often contains tracks for its descendants; don't play those twice.
        if let clip = entity.availableAnimations.first {
            let controller = entity.playAnimation(clip.repeat(duration: .infinity), transitionDuration: 0,
                                                  startsPaused: !wantsMotion || !isActive)
            plantPlaybacks[plantID, default: []].append(controller)
            return 1
        }
        return entity.children.reduce(0) { $0 + playWind(in: $1, plantID: plantID) }
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard wantsMotion != enabled else { return }
        wantsMotion = enabled
        if growthEffects?.holdingRecap == true { sharedEffects.cancel() }
        else { settleGrowthEffects() }
        applyMotion()
        updateAccessibility()
    }
    private func applyMotion() {
        for controller in playbacks {
            if wantsMotion && isActive { controller.resume() } else { controller.pause() }
        }
        for controller in visitorPlaybacks.values.flatMap({ $0 }) {
            if wantsMotion && isActive { controller.resume() } else { controller.pause() }
        }
    }
    func setActive(_ active: Bool) {
        guard !disposed else { return }
        guard isActive != active else { return }
        isActive = active
        view.isHidden = !active
        visitorRoot.isEnabled = active
        frameTime = 0
        frameCount = 0
        if active { subscribeToUpdates(); presentGrowthEffectsIfReady() }
        else {
            updateSubscription?.cancel(); updateSubscription = nil
            sharedEffects.cancel()
            if growthEffects?.holdingRecap != true { growthEffects?.cancel(); settleGrowthEffects() }
        }
        applyMotion()
        updateAccessibility()
    }

    func detachView() {
        setActive(false)
        onSelect = nil; onGroundDrag = nil
        dragging = false; dragOffset = nil; oneFingerMovesPlant = nil
        LifecycleDiagnostics.event("renderer detached id=\(diagnosticID)")
    }

    func stop() {
        guard !disposed else { return }
        setActive(false); disposed = true; visitorGeneration = UUID()
        settleGrowthEffects(); growthUpdates?.cancel(); growthUpdates = nil; growthEffects = nil
        LifecycleDiagnostics.event("renderer disposed id=\(diagnosticID)")
        visitorLoadTask?.cancel(); visitorLoadTask = nil
        visitorPlaybacks.values.flatMap { $0 }.forEach { $0.stop() }
        visitorPlaybacks.removeAll(); visitorEntities.removeAll()
        visitorAccessibility.removeAll(); view.accessibilityElements = []; cameraAccessibility = nil
        for child in Array(visitorRoot.children) { child.removeFromParent() }
        visitorTemplate = nil; visitorStore = nil; visitorAssetReady = false
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        playbacks.forEach { $0.stop() }
        plantPlaybacks.removeAll()
        previewTask?.cancel(); previewTask = nil
        preview = nil; previewKey = nil
        dragging = false; dragOffset = nil; oneFingerMovesPlant = nil
        onSelect = nil; onGroundDrag = nil
        updateSubscription?.cancel()
        updateSubscription = nil
        snapshot = nil
        placements.removeAll(); renderedPlants.removeAll(); diagnostics = []
        previewAnchor = nil; clearanceGuide = nil; selectionMarker = nil; debugGeometry = nil; board = nil
        loader.clear()
        for child in Array(root.children) { child.removeFromParent() }
        for anchor in Array(view.scene.anchors) { view.scene.removeAnchor(anchor) }
        for gesture in view.gestureRecognizers ?? [] { view.removeGestureRecognizer(gesture) }
        isLoading = false
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
    func dismissSelection() {
        selectedPlantID = nil; onSelect?(nil)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: cameraAccessibility)
        }
    }
    private func updateCamera() {
        let offset = SIMD3<Float>(sin(yaw) * cos(elevation), sin(elevation), cos(yaw) * cos(elevation)) * distance
        camera.look(at: target, from: target + offset, relativeTo: nil)
        updateAccessibility()
    }

    func setOverlayFrames(_ frames: [CGRect]) {
        guard overlayFrames != frames else { return }
        overlayFrames = frames.filter { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite }
        updateAccessibility()
    }

    private func configureAccessibility() {
        view.isAccessibilityElement = false
        let element = UIAccessibilityElement(accessibilityContainer: view)
        element.accessibilityLabel = "Garden scene"
        element.accessibilityIdentifier = "garden.scene"
        element.accessibilityTraits = .image
        element.accessibilityHint = "Use Actions to orbit, pan, zoom or reset the camera. Inspect owned plants in My plants."
        element.accessibilityCustomActions = GardenCameraAction.allCases.map { action in
            UIAccessibilityCustomAction(name: action.rawValue) { [weak self] _ in
                self?.performCameraAction(action) ?? false
            }
        }
        cameraAccessibility = element
    }

    @discardableResult
    func performCameraAction(_ action: GardenCameraAction) -> Bool {
        guard isActive, !disposed else { return false }
        switch action {
        case .zoomIn: zoom(by: 0.8)
        case .zoomOut: zoom(by: 1.2)
        case .reset: resetCamera()
        case .orbitLeft: yaw -= 0.2; updateCamera()
        case .orbitRight: yaw += 0.2; updateCamera()
        case .tiltUp: elevation = min(elevation + 0.15, 1.35); updateCamera()
        case .tiltDown: elevation = max(elevation - 0.15, 0.25); updateCamera()
        case .panLeft: panCamera(CGPoint(x: 60, y: 0))
        case .panRight: panCamera(CGPoint(x: -60, y: 0))
        case .panForward: panCamera(CGPoint(x: 0, y: 60))
        case .panBack: panCamera(CGPoint(x: 0, y: -60))
        }
        return true
    }

    private func updateAccessibility() {
        guard isActive, !disposed, let cameraElement = cameraAccessibility else {
            view.accessibilityElements = []; accessibilityIDs = nil
            visitorAccessibility.removeAll()
            return
        }
        cameraElement.accessibilityFrameInContainerSpace = view.bounds
        var ids: [UUID] = []
        for visitor in visitorStore?.visibleOpportunities ?? [] {
            guard let rect = visitorHitTarget(visitor.id)?.accessibleRect(excluding: overlayFrames) else { continue }
            let element = visitorAccessibility[visitor.id] ?? GardenAccessibilityElement(accessibilityContainer: view)
            element.accessibilityLabel = "Welcome visitor"
            element.accessibilityHint = "Earn \(visitor.tokens) visitor tokens after server confirmation"
            element.accessibilityIdentifier = "visitors.butterfly.\(visitor.id.uuidString)"
            element.accessibilityTraits = visitorStore?.canRequestReward == true ? .button : [.button, .notEnabled]
            element.accessibilityFrameInContainerSpace = rect
            let id = visitor.id
            element.activate = { [weak self] in self?.activateVisitor(id) ?? false }
            visitorAccessibility[id] = element; ids.append(id)
        }
        visitorAccessibility = visitorAccessibility.filter { ids.contains($0.key) }
        if accessibilityIDs != ids {
            let elements: [UIAccessibilityElement] = ids.compactMap { visitorAccessibility[$0] }
            view.accessibilityElements = elements + [cameraElement]
            accessibilityIDs = ids
        }
    }

    @discardableResult
    func activateVisitor(_ id: UUID) -> Bool {
        guard isActive, let store = visitorStore, store.canRequestReward,
              let visitor = store.visibleOpportunities.first(where: { $0.id == id }),
              visitorHitTarget(id)?.accessibleRect(excluding: overlayFrames) != nil else { return false }
        Task { await store.welcome(visitor) }
        return true
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
        sharedEffects.tick(delta)
        updateVisitors()
        frameTime += delta
        frameCount += 1
        if frameTime >= 1 {
            sceneUpdateMilliseconds = frameTime / Double(frameCount) * 1000
            frameTime = 0
            frameCount = 0
        }
    }

    func setVisitors(_ store: VisitorCoordinator?) {
        guard !disposed else { return }
        if visitorStore?.id != store?.id {
            visitorPlaybacks.values.flatMap { $0 }.forEach { $0.stop() }
            visitorPlaybacks.removeAll(); visitorEntities.removeAll()
            for child in Array(visitorRoot.children) { child.removeFromParent() }
        }
        visitorStore = store
        updateAccessibility()
        guard store != nil, visitorTemplate == nil, visitorLoadTask == nil else { return }
        if let cached = visitorModels.cachedClone() {
            visitorTemplate = cached; visitorAssetReady = true; visitorAssetIssue = nil
            updateVisitors()
            LifecycleDiagnostics.event("butterfly attached from cache renderer=\(diagnosticID)")
            return
        }
        let token = UUID(); visitorGeneration = token
        visitorAssetIssue = nil
        let rendererID = diagnosticID
        let models = visitorModels
        visitorLoadTask = Task { [weak self] in
            do {
                let adapter = try await models.load()
                try Task.checkCancellation()
                guard let self = self, !self.disposed, self.visitorGeneration == token else { return }
                self.visitorTemplate = adapter; self.visitorAssetReady = true; self.visitorAssetIssue = nil
                self.visitorLoadTask = nil; self.updateVisitors()
                LifecycleDiagnostics.event("butterfly ready renderer=\(rendererID)")
            } catch is CancellationError { }
            catch {
                guard let self = self, !self.disposed, self.visitorGeneration == token else { return }
                self.visitorLoadTask = nil
                self.visitorAssetIssue = (error as? VisitorAssetLoadError)?.errorDescription ??
                    "Visitor artwork is unavailable. You can still welcome visitors."
                LifecycleDiagnostics.event("butterfly failed renderer=\(rendererID)")
            }
        }
    }

    func projectedVisitor(_ id: UUID) -> CGPoint? {
        // Presentation only; actual model hit geometry is calculated at tap time.
        guard visitorStore?.eligible == true, isActive, let entity = visitorEntities[id],
              camera.convert(position: entity.position(relativeTo: nil), from: nil).z < 0,
              let point = view.project(entity.position(relativeTo: nil)), view.bounds.contains(point) else { return nil }
        return point
    }

    func visitorHitTarget(_ id: UUID) -> VisitorHitTarget? {
        guard visitorStore?.eligible == true, isActive, let entity = visitorEntities[id] else { return nil }
        let bounds = entity.visualBounds(relativeTo: nil)
        // RealityKit may project points behind the camera as well.
        guard camera.convert(position: bounds.center, from: nil).z < 0 else { return nil }
        var points: [CGPoint] = []
        for x in [bounds.min.x, bounds.max.x] {
            for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    let world = SIMD3<Float>(x, y, z)
                    guard camera.convert(position: world, from: nil).z < 0,
                          let point = view.project(world), point.x.isFinite, point.y.isFinite else { return nil }
                    points.append(point)
                }
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return VisitorHitTarget(id: id, artwork: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                                viewport: view.bounds)
    }

    @discardableResult
    func welcomeVisitor(at point: CGPoint) -> Bool {
        guard !overlayFrames.contains(where: { $0.contains(point) }),
              let store = visitorStore, store.canRequestReward else { return false }
        let visitors = store.visibleOpportunities
        let targets = visitors.compactMap { visitorHitTarget($0.id) }
        guard let id = VisitorHitTarget.pick(at: point, from: targets),
              let visitor = visitors.first(where: { $0.id == id }) else { return false }
        Task { await store.welcome(visitor) }
        return true
    }

    private func updateVisitors() {
        defer { updateAccessibility() }
        guard let store = visitorStore, let garden = snapshot, let now = store.serverNow else { return }
        let visitors = store.eligible ? store.visibleOpportunities : []
        let wanted = Set(visitors.map(\.id))
        for id in Array(visitorEntities.keys) where !wanted.contains(id) {
            visitorPlaybacks.removeValue(forKey: id)?.forEach { $0.stop() }
            visitorEntities.removeValue(forKey: id)?.removeFromParent()
        }
        guard let template = visitorTemplate else { return }
        for visitor in visitors {
            if visitorEntities[visitor.id] == nil {
                let entity = Entity()
                let model = template.clone(recursive: true)
                model.scale = SIMD3(repeating: 1.5)
                entity.addChild(model); visitorRoot.addChild(entity)
                visitorEntities[visitor.id] = entity
                func play(_ node: Entity) {
                    if let animation = node.availableAnimations.first {
                        visitorPlaybacks[visitor.id, default: []].append(node.playAnimation(animation.repeat(duration: .infinity),
                            transitionDuration: 0, startsPaused: !wantsMotion || !isActive))
                    } else { for child in node.children { play(child) } }
                }
                play(model)
            }
            let height = max(1.6, (diagnostics.map { $0.minimumY + $0.bounds.y }.max() ?? 1) + 0.25)
            let pose = VisitorWorldPose(elapsed: now.timeIntervalSince(visitor.issuedAt), remaining: visitor.expiresAt.timeIntervalSince(now),
                lane: visitor.lane ?? 1, width: Float(garden.width * garden.gardenUnitMetres),
                depth: Float(garden.depth * garden.gardenUnitMetres), height: height, reduceMotion: !wantsMotion)
            visitorEntities[visitor.id]?.position = pose.position
            visitorEntities[visitor.id]?.orientation = simd_quatf(angle: pose.heading, axis: [0, 1, 0])
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
        if preview?.movable == true { return false }
        return (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer) ||
        (otherGestureRecognizer is UIPinchGestureRecognizer && gestureRecognizer is UIPanGestureRecognizer)
    }
    @objc private func orbitGesture(_ gesture: UIPanGestureRecognizer) {
        handleSingleFingerPan(state: gesture.state, translation: gesture.translation(in: view),
                              location: gesture.location(in: view))
        gesture.setTranslation(.zero, in: view)
    }

    // Lock ownership at the beginning. Cancelling/invalidating a plant preview
    // during a drag must never turn its remaining events into camera movement.
    func handleSingleFingerPan(state: UIGestureRecognizer.State, translation: CGPoint, location: CGPoint) {
        if state == .began { oneFingerMovesPlant = preview?.movable == true }
        defer {
            if state == .ended || state == .cancelled || state == .failed {
                oneFingerMovesPlant = nil; dragging = false; dragOffset = nil
            }
        }
        guard let movesPlant = oneFingerMovesPlant else { return }
        if movesPlant {
            moveGesture(state: state, translation: translation, point: location)
            return
        }
        guard state == .began || state == .changed || state == .ended else { return }
        let change = translation
        yaw -= Float(change.x) * 0.007
        elevation = min(max(elevation + Float(change.y) * 0.005, 0.25), 1.35)
        updateCamera()
    }
    @objc private func panGesture(_ gesture: UIPanGestureRecognizer) {
        if dragging { dragging = false; onGroundDrag?(nil, .cancelled) }
        let change = gesture.translation(in: view)
        panCamera(change)
        gesture.setTranslation(.zero, in: view)
    }
    private func panCamera(_ change: CGPoint) {
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        target += (-right * Float(change.x) - forward * Float(change.y)) * distance * 0.0015
        if let garden = snapshot {
            target.x = min(max(target.x, 0), Float(garden.width * garden.gardenUnitMetres))
            target.z = min(max(target.z, 0), Float(garden.depth * garden.gardenUnitMetres))
        }
        updateCamera()
    }
    @objc private func pinchGesture(_ gesture: UIPinchGestureRecognizer) {
        if dragging { dragging = false; onGroundDrag?(nil, .cancelled) }
        zoom(by: 1 / Float(max(gesture.scale, 0.01)))
        gesture.scale = 1
    }
    @objc private func tapGesture(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        if preview?.movable == true {
            let hit = groundPoint(point)
            onGroundDrag?(hit, .changed)
            onGroundDrag?(hit, .ended)
            return
        }
        if welcomeVisitor(at: point) { return }
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

    private func groundPoint(_ point: CGPoint) -> SIMD2<Double>? {
        guard let garden = snapshot, let ray = view.ray(through: point), abs(ray.direction.y) > 0.00001 else { return nil }
        let t = -ray.origin.y / ray.direction.y
        guard t >= 0 else { return nil }
        let hit = ray.origin + ray.direction * t
        return SIMD2(Double(hit.x) / garden.gardenUnitMetres, Double(hit.z) / garden.gardenUnitMetres)
    }

    private func moveGesture(state: UIGestureRecognizer.State, translation: CGPoint, point: CGPoint) {
        guard let preview = preview else { return }
        switch state {
        case .began:
            dragging = true
            let start = groundPoint(CGPoint(x: point.x - translation.x, y: point.y - translation.y))
            dragOffset = start.map { SIMD2(preview.plant.x, preview.plant.y) - $0 }
            onGroundDrag?(nil, .began)
        case .changed, .ended:
            let hit = groundPoint(point).map { $0 + (dragOffset ?? .zero) }
            onGroundDrag?(hit, state == .ended ? .ended : .changed)
            if state == .ended { dragging = false; dragOffset = nil }
        case .cancelled, .failed:
            dragging = false; dragOffset = nil; onGroundDrag?(nil, .cancelled)
        default: break
        }
    }

    func updatePreview(_ value: EditorRenderPreview?, catalog: any AssetCatalogProviding) {
        guard !disposed else { return }
        if let old = preview, old.plant.id != value?.plant.id || value == nil,
           let plant = snapshot?.plants.first(where: { $0.id == old.plant.id }), let garden = snapshot,
           let entity = placements[plant.id] {
            entity.isEnabled = true
            transform(entity, plant: plant, garden: garden)
        }
        preview = value
        guard let value = value, let garden = snapshot else {
            clearanceGuide?.removeFromParent(); clearanceGuide = nil; guideStyle = nil
            previewTask?.cancel(); previewTask = nil
            previewAnchor?.removeFromParent(); previewAnchor = nil; previewKey = nil
            return
        }
        if let placed = placements[value.plant.id] {
            transform(placed, plant: value.plant, garden: garden)
            placed.isEnabled = !value.adult || value.plant.growthStage == .adult
        }
        if let radius = value.radius {
            let style = "\(radius)|\(garden.gardenUnitMetres)|\(value.valid)"
            if style != guideStyle || clearanceGuide == nil {
                clearanceGuide?.removeFromParent()
                let guide = Entity()
                let radiusMetres = Float(radius * garden.gardenUnitMetres)
                let color: UIColor = value.valid ? .systemGreen : .systemRed
                for index in 0..<48 {
                    let angle = Float(index) * 2 * .pi / 48
                    let segment = ModelEntity(mesh: .generateBox(size: [max(radiusMetres * 0.13, 0.01), 0.015, 0.025]),
                                              materials: [UnlitMaterial(color: color)])
                    segment.position = [sin(angle) * radiusMetres, 0.025, cos(angle) * radiusMetres]
                    segment.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
                    guide.addChild(segment)
                }
                root.addChild(guide); clearanceGuide = guide; guideStyle = style
            }
            clearanceGuide?.position = GardenCoordinates.world(x: value.plant.x, y: value.plant.y, unitMetres: garden.gardenUnitMetres)
        } else {
            clearanceGuide?.removeFromParent(); clearanceGuide = nil; guideStyle = nil
        }
        let needsCandidate = placements[value.plant.id] == nil
        let key = "\(value.plant.id)|\(value.plant.assetVersion)|\(value.plant.growthStage)|\(needsCandidate)|\(value.adult)"
        if previewKey != key {
            previewTask?.cancel(); previewAnchor?.removeFromParent()
            let anchor = Entity(); root.addChild(anchor); previewAnchor = anchor; previewKey = key
            previewTask = Task { [weak self] in
                guard let self = self else { return }
                do {
                    if needsCandidate && (!value.adult || value.plant.growthStage == .adult) {
                        let loaded = try await self.loader.load(catalog.resolve(value.plant))
                        guard !Task.isCancelled, self.previewKey == key else { return }
                        self.modelLoadCount += 1
                        self.removeCollisions(loaded.entity)
                        anchor.addChild(loaded.entity)
                    }
                    if value.adult && value.plant.growthStage != .adult {
                        var adult = value.plant; adult.growthStage = .adult
                        let loaded = try await self.loader.load(catalog.resolve(adult))
                        guard !Task.isCancelled, self.previewKey == key else { return }
                        self.modelLoadCount += 1
                        self.removeCollisions(loaded.entity)
                        anchor.addChild(loaded.entity)
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.previewKey == key else { return }
                    self.errors.append("Preview: \(error.localizedDescription)")
                }
            }
        }
        if let anchor = previewAnchor { transform(anchor, plant: value.plant, garden: garden) }
        updateSelection()
    }

    private func removeCollisions(_ entity: Entity) {
        entity.components.remove(CollisionComponent.self)
        for child in entity.children { removeCollisions(child) }
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
    var editorPreview: EditorRenderPreview? = nil
    var growthEffects: GardenEffectsCoordinator? = nil
    var onSelect: ((UUID?) -> Void)? = nil
    var onGroundDrag: ((SIMD2<Double>?, GardenDragPhase) -> Void)? = nil

    final class Coordinator {
        weak var renderer: RealityGardenRenderer?
        init(renderer: RealityGardenRenderer) { self.renderer = renderer }
    }
    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }
    func makeUIView(context: Context) -> ARView { renderer.view }
    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.renderer?.detachView()
    }
    func updateUIView(_ uiView: ARView, context: Context) {
        renderer.setGrowthEffects(growthEffects)
        renderer.display(garden, catalog: catalog)
        renderer.setMotionEnabled(motionEnabled)
        renderer.setActive(active)
        renderer.setDebugOptions(bounds: showBounds, groundPicking: groundPicking)
        renderer.onSelect = onSelect
        renderer.onGroundDrag = onGroundDrag
        renderer.updatePreview(editorPreview, catalog: catalog)
    }
}
