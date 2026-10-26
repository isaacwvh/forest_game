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

    func load() async throws -> Entity {
        if let template = template { return template.clone(recursive: true) }
        let operation: Task<Entity, Error>
        let token: UUID
        if let loading = loading { operation = loading; token = generation }
        else {
            loadCount += 1
            let id = UUID()
            generation = id; token = id
            operation = Task {
                LifecycleDiagnostics.event("butterfly load started id=\(id)")
                defer { LifecycleDiagnostics.event("butterfly load ended id=\(id)") }
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
            loading = operation
        }
        do {
            let imported = try await operation.value
            if generation == token { template = imported; loading = nil }
            return imported.clone(recursive: true)
        } catch {
            if generation == token { loading = nil }
            throw error
        }
    }
}
