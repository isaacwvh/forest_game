import Combine
import RealityKit
import UIKit

/// Cosmetic scenery only. The planting plane, camera and all game entities stay
/// owned by RealityGardenRenderer. Imported art never participates in hit tests.
@MainActor
final class GardenEnvironment {
    static let authoredWidth: Float = 10
    static let authoredDepth: Float = 10
    static let backdropDistance: Float = 200

    private let islandURL: URL?
    private let backdropURL: URL?
    private let importIsland: @MainActor (URL) -> AnyPublisher<Entity, Error>
    private var islandRequest: AnyCancellable?
    private var backdropRequest: AnyCancellable?
    private var islandTemplate: Entity?
    private weak var currentIsland: Entity?
    private weak var backdropCamera: Entity?
    private var backdrop: ModelEntity?
    private var backdropAspect: Float = 2 / 3
    private var lastViewport = CGSize.zero
    private var lastFieldOfView: Float = 0
    private var stopped = false

    init(bundle: Bundle = .main,
         importIsland: @escaping @MainActor (URL) -> AnyPublisher<Entity, Error> = {
             Entity.loadAsync(contentsOf: $0).eraseToAnyPublisher()
         }) {
        islandURL = bundle.url(forResource: "floating-island", withExtension: "usdz",
                               subdirectory: "garden-environment/v1")
        backdropURL = bundle.url(forResource: "mountain-mist-backdrop", withExtension: "png",
                                 subdirectory: "garden-environment/v1")
        self.importIsland = importIsland
    }

    func makeIsland(width: Float, depth: Float) -> Entity {
        let island = Entity()
        island.name = "garden-island"
        // Top-centre pivot, not the lowest point of the artwork's bounds.
        island.position = [width / 2, 0, depth / 2]
        currentIsland = island
        if let template = islandTemplate {
            install(template, in: island, width: width, depth: depth)
        } else {
            // Retain the existing Y=0 surface during loading or an artwork failure.
            let fallback = ModelEntity(mesh: .generateBox(size: [width, 0.22, depth], cornerRadius: 0.10),
                materials: [SimpleMaterial(color: UIColor(red: 0.45, green: 0.57, blue: 0.36, alpha: 1),
                                           roughness: 1, isMetallic: false)])
            fallback.name = "garden-island-fallback"
            fallback.position.y = -0.11
            island.addChild(fallback)
            loadIslandIfNeeded()
        }
        return island
    }

    private func loadIslandIfNeeded() {
        guard !stopped, islandTemplate == nil, islandRequest == nil, let url = islandURL else { return }
        // Delivery is queued so even a synchronously cached publisher cannot
        // finish before its cancellation handle has been assigned.
        islandRequest = importIsland(url).prefix(1).receive(on: DispatchQueue.main).sink(
            receiveCompletion: { [weak self] completion in
                guard let self = self, !self.stopped else { return }
                self.islandRequest = nil
                if case .failure = completion { LifecycleDiagnostics.event("Garden island artwork unavailable; using flat surface") }
            }, receiveValue: { [weak self] template in
                guard let self = self, !self.stopped else { return }
                self.removeCollisions(from: template)
                self.islandTemplate = template
                guard let island = self.currentIsland,
                      let fallback = island.findEntity(named: "garden-island-fallback") else { return }
                let size = fallback.visualBounds(relativeTo: island).extents
                self.install(template, in: island, width: size.x, depth: size.z)
            })
    }

    private func install(_ template: Entity, in island: Entity, width: Float, depth: Float) {
        let visual = template.clone(recursive: true)
        visual.name = "garden-island-visual"
        visual.scale = [width / Self.authoredWidth, min(width, depth) / Self.authoredWidth,
                        depth / Self.authoredDepth]
        for child in Array(island.children) { child.removeFromParent() }
        island.addChild(visual)
    }

    func attachBackdrop(to camera: Entity) {
        guard !stopped, backdropCamera == nil, let url = backdropURL else { return }
        backdropCamera = camera
        backdropRequest = TextureResource.loadAsync(contentsOf: url, options: .init(semantic: .color))
            .receive(on: DispatchQueue.main).sink(receiveCompletion: { [weak self] completion in
                guard let self = self, !self.stopped else { return }
                self.backdropRequest = nil
                if case .failure = completion { LifecycleDiagnostics.event("Garden backdrop unavailable; using sage background") }
            }, receiveValue: { [weak self] texture in
                guard let self = self, !self.stopped, let camera = self.backdropCamera else { return }
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                // XY plane faces the camera; the image is not flipped or wrapped.
                let backdrop = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
                backdrop.name = "garden-static-backdrop"
                backdrop.position.z = -Self.backdropDistance
                backdrop.isEnabled = false
                self.backdropAspect = Float(texture.width) / Float(texture.height)
                self.backdrop = backdrop
                camera.addChild(backdrop)
            })
    }

    func updateBackdrop(in view: ARView, camera: PerspectiveCamera) {
        let viewport = view.bounds.size
        let fieldOfView = camera.camera.fieldOfViewInDegrees
        guard !stopped, let backdrop = backdrop,
              viewport.width > 0, viewport.height > 0,
              viewport != lastViewport || fieldOfView != lastFieldOfView,
              let ray = view.ray(through: CGPoint(x: view.bounds.maxX, y: view.bounds.minY)) else { return }
        // Derive the visible rectangle from the existing projection. This also
        // handles camera FOV orientation without changing any camera settings.
        let origin = camera.convert(position: ray.origin, from: nil)
        let direction = camera.convert(position: ray.origin + ray.direction, from: nil) - origin
        guard direction.z < -0.00001 else { return }
        let distance = (-Self.backdropDistance - origin.z) / direction.z
        guard distance > 0 else { return }
        let corner = origin + direction * distance
        guard let size = Self.backdropSize(visibleSize: [abs(corner.x) * 2, abs(corner.y) * 2],
                                           imageAspect: backdropAspect) else { return }
        // Tiny overscan prevents a pixel seam from projection rounding.
        backdrop.scale = [size.x * 1.002, size.y * 1.002, 1]
        backdrop.isEnabled = true
        lastViewport = viewport
        lastFieldOfView = fieldOfView
    }

    /// Aspect-fill at a fixed camera-relative distance, independent of garden
    /// dimensions or camera orbit, pan and zoom. No viewport space is reserved.
    static func backdropSize(visibleSize: SIMD2<Float>, imageAspect: Float) -> SIMD2<Float>? {
        guard visibleSize.x.isFinite, visibleSize.y.isFinite, visibleSize.x > 0, visibleSize.y > 0,
              imageAspect.isFinite, imageAspect > 0 else { return nil }
        let width = visibleSize.x, height = visibleSize.y
        return width / height > imageAspect ? [width, width / imageAspect] : [height * imageAspect, height]
    }

    func stop() {
        stopped = true
        islandRequest?.cancel(); islandRequest = nil
        backdropRequest?.cancel(); backdropRequest = nil
        islandTemplate = nil; currentIsland = nil
        backdrop?.removeFromParent(); backdrop = nil; backdropCamera = nil
    }

    private func removeCollisions(from entity: Entity) {
        entity.components.remove(CollisionComponent.self)
        for child in entity.children { removeCollisions(from: child) }
    }
}
