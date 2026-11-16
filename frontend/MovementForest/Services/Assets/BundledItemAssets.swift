import Foundation

struct ItemAssetManifest: Decodable {
    struct File: Decodable { let file: String; let bytes: Int; let sha256: String }
    struct UI: Decodable { let thumbnail: String }
    struct Animation: Decodable { let name: String; let durationSeconds: Double; let loop: Bool; let rootMotion: Bool }
    let schemaVersion: Int
    let assetKind: String
    let itemId: String
    let assetVersion: String
    let format: String
    let units: String
    let exportUpAxis: String
    let bounds: AssetBounds
    let ui: UI
    let assets: [File]
    let animation: Animation?
}

struct ResolvedItemAsset {
    let key: String
    let modelURL: URL
    let thumbnailURL: URL
    let bytes: Int
    let sha256: String
    let bounds: AssetBounds
    var animated: Bool = false
}

enum BundledItemAssets {
    static func resolve(_ item: GardenItem, bundle: Bundle = .main) throws -> ResolvedItemAsset {
        guard let root = bundle.resourceURL else { throw ForestError.missingResource("item assets") }
        return try resolve(item, resourceRoot: root)
    }

    static func resolve(_ item: GardenItem, resourceRoot: URL) throws -> ResolvedItemAsset {
        let index = resourceRoot.appendingPathComponent("Fixtures/item-asset-index.json")
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: index))
        func safe(_ path: String, root: URL) throws -> URL {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  !path.split(separator: "/").contains("..") else {
                throw ForestError.invalidData("Invalid item asset path.")
            }
            return root.appendingPathComponent(path)
        }
        for path in paths {
            let manifestURL = try safe(path, root: resourceRoot)
            let manifest = try JSONDecoder().decode(ItemAssetManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.itemId == item.itemId && manifest.assetVersion == item.assetVersion else { continue }
            guard manifest.schemaVersion == 1, manifest.assetKind == "item", manifest.format == "usdz",
                  manifest.units == "metres", manifest.exportUpAxis == "Y",
                  manifest.bounds.min.count == 3, manifest.bounds.max.count == 3,
                  zip(manifest.bounds.min, manifest.bounds.max).allSatisfy({ pair in pair.0.isFinite && pair.1.isFinite && pair.0 <= pair.1 }),
                  let model = manifest.assets.first(where: { $0.file.hasSuffix(".usdz") }),
                  model.bytes > 0, model.sha256.count == 64 else {
                throw ForestError.invalidData("Invalid item manifest.")
            }
            let folder = manifestURL.deletingLastPathComponent()
            let prefix = "assets/items/" + (path as NSString).deletingLastPathComponent + "/"
            guard item.modelKey == prefix + model.file, item.thumbnailKey == prefix + manifest.ui.thumbnail else {
                throw ForestError.invalidData("Item assets do not match their published version.")
            }
            return ResolvedItemAsset(key: "item/\(item.itemId)/\(item.assetVersion)",
                modelURL: try safe(model.file, root: folder), thumbnailURL: try safe(manifest.ui.thumbnail, root: folder),
                bytes: model.bytes, sha256: model.sha256, bounds: manifest.bounds, animated: manifest.animation != nil)
        }
        throw ForestError.missingResource("item \(item.itemId) version \(item.assetVersion)")
    }
}

struct RuntimeModelAsset {
    let key: String
    let modelURL: URL
    let bytes: Int
    let sha256: String
    let bounds: AssetBounds
    let correctZUp: Bool
}
