import Foundation
import RealityKit
import CryptoKit
import Combine

/// One immutable bundled template for the process. Scene entities and animation
/// controllers belong to each renderer; a replacement never reimports this asset.
@MainActor
final class VisitorModelLibrary {
    static let shared = VisitorModelLibrary()
    private var template: Entity?
    private var loading: Task<Entity, Error>?
    private var generation = UUID()
    private(set) var loadCount = 0
    private let importer: @MainActor () async throws -> Entity

    init(importer: (@MainActor () async throws -> Entity)? = nil) {
        self.importer = importer ?? { try await VisitorModelLibrary.importTemplate() }
    }

    /// Begin importing at app startup, before authentication or visitor issuance.
    /// The single owned task fills the cache even when no renderer is attached.
    func preload() {
        guard template == nil else { return }
        _ = startLoading()
    }

    func cachedClone() -> Entity? { template?.clone(recursive: true) }

    func load() async throws -> Entity {
        if let cached = cachedClone() { return cached }
        let imported = try await startLoading().value
        try Task.checkCancellation()
        return imported.clone(recursive: true)
    }

    private func startLoading() -> Task<Entity, Error> {
        if let loading = loading { return loading }
        loadCount += 1
        let token = UUID(); generation = token
        let importer = importer
        let operation = Task { [weak self] in
            LifecycleDiagnostics.event("butterfly load started id=\(token)")
            defer { LifecycleDiagnostics.event("butterfly load ended id=\(token)") }
            do {
                let imported = try await importer()
                if let self = self, self.generation == token {
                    self.template = imported; self.loading = nil
                }
                return imported
            } catch {
                if let self = self, self.generation == token { self.loading = nil }
                LifecycleDiagnostics.event("butterfly import failed id=\(token)")
                throw error
            }
        }
        loading = operation
        return operation
    }

    private static func importTemplate() async throws -> Entity {
        let (manifest, url) = try VisitorAssetManifest.load()
        let asset = manifest.assets[0]
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == asset.bytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                throw ForestError.invalidData("Butterfly checksum mismatch.")
            }
        }.value
        for try await imported in Entity.loadAsync(contentsOf: url).values {
            func hasAnimation(_ node: Entity) -> Bool {
                !node.availableAnimations.isEmpty || node.children.contains { hasAnimation($0) }
            }
            guard hasAnimation(imported) else { throw ForestError.assetLoad("Butterfly wing animation is unavailable.") }
            let adapter = Entity(); adapter.addChild(imported)
            if AssetOrientation.needsZUpCorrection(imported: imported.visualBounds(relativeTo: adapter).extents,
                                                  authored: asset.bounds.extents) {
                adapter.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            }
            return adapter
        }
        throw ForestError.assetLoad("No butterfly model was imported.")
    }
}
