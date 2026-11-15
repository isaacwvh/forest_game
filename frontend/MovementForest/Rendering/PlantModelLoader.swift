import Foundation
import RealityKit
import Combine
import CryptoKit
import UIKit

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
    private var inFlight: [String: Task<LoadedModel, Error>] = [:]
    private var inFlightIDs: [String: UUID] = [:]
    private var activeImports = 0
    private var memoryWarning: AnyCancellable?

    init() {
        memoryWarning = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.clear() } }
    }

    func load(_ resolved: ResolvedPlantAsset) async throws -> LoadedModel {
        try await load(RuntimeModelAsset(key: resolved.key, modelURL: resolved.modelURL,
            bytes: resolved.asset.bytes, sha256: resolved.asset.sha256,
            bounds: resolved.asset.bounds, correctZUp: true))
    }

    func load(_ resolved: ResolvedItemAsset) async throws -> LoadedModel {
        try await load(RuntimeModelAsset(key: resolved.key, modelURL: resolved.modelURL,
            bytes: resolved.bytes, sha256: resolved.sha256, bounds: resolved.bounds, correctZUp: false))
    }

    private func load(_ resolved: RuntimeModelAsset) async throws -> LoadedModel {
        if let cached = templates[resolved.key] {
            touch(resolved.key)
            return LoadedModel(entity: cached.entity.clone(recursive: true), orientationNote: cached.orientationNote)
        }
        if let task = inFlight[resolved.key] {
            let value = try await task.value
            try Task.checkCancellation()
            return LoadedModel(entity: value.entity.clone(recursive: true), orientationNote: value.orientationNote)
        }
        let task = Task { @MainActor in try await self.importModel(resolved) }
        let requestID = UUID()
        inFlight[resolved.key] = task; inFlightIDs[resolved.key] = requestID
        defer {
            if inFlightIDs[resolved.key] == requestID {
                inFlight.removeValue(forKey: resolved.key); inFlightIDs.removeValue(forKey: resolved.key)
            }
        }
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }

    private func importModel(_ resolved: RuntimeModelAsset) async throws -> LoadedModel {
        while activeImports >= 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        activeImports += 1
        defer { activeImports -= 1 }
        let url = resolved.modelURL
        let size = resolved.bytes
        let checksum = resolved.sha256
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
            let correct = resolved.correctZUp && AssetOrientation.needsZUpCorrection(imported: importedSize, authored: resolved.bounds.extents)
            if correct { adapter.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]) }
            let note = correct ? "Applied Z-up → Y-up once" : "Importer supplied Y-up"
            templates[resolved.key] = Template(entity: adapter, orientationNote: note)
            touch(resolved.key)
            while recency.count > capacity {
                templates.removeValue(forKey: recency.removeFirst())
            }
            return LoadedModel(entity: adapter.clone(recursive: true), orientationNote: note)
        }
        throw ForestError.assetLoad("The model loader returned no entity for \(resolved.modelURL.lastPathComponent).")
    }

    func clear() {
        templates.removeAll(); recency.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll(); inFlightIDs.removeAll()
    }
    private func touch(_ key: String) { recency.removeAll { $0 == key }; recency.append(key) }
}
