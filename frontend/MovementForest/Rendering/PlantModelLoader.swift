import Foundation
import RealityKit
import Combine
import CryptoKit

@MainActor
final class PlantModelLoader {
    struct LoadedModel {
        let entity: Entity
        let orientationNote: String
    }
    private struct Template {
        let entity: Entity
        let orientationNote: String
    }
    private var templates: [String: Template] = [:]
    private var recency: [String] = []
    private let capacity = 20

    func load(_ resolved: ResolvedPlantAsset) async throws -> LoadedModel {
        if let cached = templates[resolved.key] {
            touch(resolved.key)
            return LoadedModel(entity: cached.entity.clone(recursive: true), orientationNote: cached.orientationNote)
        }
        let url = resolved.modelURL
        let size = resolved.asset.bytes
        let checksum = resolved.asset.sha256
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw ForestError.invalidData("Asset checksum mismatch for \(url.lastPathComponent). Restore the matching package and rebuild.")
            }
        }.value
        try Task.checkCancellation()
        // Load the complete hierarchy so rigs and animation bindings survive.
        for try await imported in Entity.loadAsync(contentsOf: url).values {
            try Task.checkCancellation()
            let adapter = Entity()
            adapter.name = "asset-adapter"
            adapter.addChild(imported)
            let importedSize = imported.visualBounds(relativeTo: adapter).extents
            let correct = AssetOrientation.needsZUpCorrection(imported: importedSize, authored: resolved.asset.bounds.extents)
            if correct { adapter.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]) }
            let note = correct ? "Applied Z-up → Y-up once" : "Importer supplied Y-up"
            templates[resolved.key] = Template(entity: adapter, orientationNote: note)
            touch(resolved.key)
            while recency.count > capacity {
                templates.removeValue(forKey: recency.removeFirst())
            }
            return LoadedModel(entity: adapter.clone(recursive: true), orientationNote: note)
        }
        throw ForestError.assetLoad("The model loader returned no entity for \(resolved.asset.file).")
    }

    func clear() { templates.removeAll(); recency.removeAll() }
    private func touch(_ key: String) { recency.removeAll { $0 == key }; recency.append(key) }
}
