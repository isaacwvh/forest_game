import Foundation

protocol AssetCatalogProviding {
    var species: [SpeciesManifest] { get }
    func resolve(speciesId: String, version: String, stage: GrowthStage, variant: String) throws -> ResolvedPlantAsset
}

struct BundleAssetCatalog: AssetCatalogProviding {
    let species: [SpeciesManifest]
    private let resourceRoot: URL
    private let roots: [String: URL]

    init(bundle: Bundle = .main) throws {
        guard let root = bundle.resourceURL else { throw ForestError.missingResource("app resources") }
        try self.init(resourceRoot: root)
    }

    init(resourceRoot: URL) throws {
        self.resourceRoot = resourceRoot
        let index = resourceRoot.appendingPathComponent("Fixtures/asset-index.json")
        let identifiers = try JSONDecoder().decode([String].self, from: Data(contentsOf: index))
        guard !identifiers.isEmpty, Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({ $0.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil }) else {
            throw ForestError.invalidData("The bundled asset index is invalid.")
        }
        let manifestIndex = resourceRoot.appendingPathComponent("Fixtures/asset-manifests.json")
        let paths = FileManager.default.fileExists(atPath: manifestIndex.path)
            ? try JSONDecoder().decode([String].self, from: Data(contentsOf: manifestIndex))
            : identifiers.map { "\($0)/v1/\($0).json" }
        var loaded: [SpeciesManifest] = []
        var resolvedRoots: [String: URL] = [:]
        for path in paths {
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains("..") else {
                throw ForestError.invalidData("Invalid bundled manifest path.")
            }
            let url = resourceRoot.appendingPathComponent(path)
            let manifest = try JSONDecoder().decode(SpeciesManifest.self, from: Data(contentsOf: url)).validated()
            let key = manifest.speciesId + "/" + manifest.assetVersion
            guard identifiers.contains(manifest.speciesId), resolvedRoots[key] == nil else {
                throw ForestError.invalidData("Duplicate or unknown bundled manifest.")
            }
            loaded.append(manifest); resolvedRoots[key] = url.deletingLastPathComponent()
        }
        guard Set(loaded.map(\.speciesId)) == Set(identifiers) else {
            throw ForestError.invalidData("The bundled manifests do not cover the catalog.")
        }
        species = loaded; roots = resolvedRoots
    }

    func resolve(speciesId: String, version: String, stage: GrowthStage, variant: String) throws -> ResolvedPlantAsset {
        guard let manifest = species.first(where: { $0.speciesId == speciesId && $0.assetVersion == version }),
              let asset = manifest.assets.first(where: { $0.stage == stage && $0.variant == variant }) else {
            throw ForestError.invalidData("No asset for \(speciesId), \(variant), \(stage.title), version \(version).")
        }
        guard let root = roots[speciesId + "/" + version] else {
            throw ForestError.missingResource("plant package")
        }
        func safeURL(_ path: String) throws -> URL {
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains("..") else {
                throw ForestError.invalidData("Invalid asset path.")
            }
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ForestError.missingResource(path) }
            return url
        }
        return try ResolvedPlantAsset(manifest: manifest, asset: asset,
                                      modelURL: safeURL(asset.file), thumbnailURL: safeURL(asset.thumbnail))
    }
}

extension AssetCatalogProviding {
    func resolve(_ plant: GardenPlant) throws -> ResolvedPlantAsset {
        try resolve(speciesId: plant.speciesId, version: plant.assetVersion,
                    stage: plant.growthStage, variant: plant.variantId)
    }
}
