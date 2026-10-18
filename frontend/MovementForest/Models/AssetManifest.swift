import Foundation
import simd

struct AssetBounds: Codable {
    let min: [Float]
    let max: [Float]
    var extents: SIMD3<Float> {
        SIMD3(max[0] - min[0], max[1] - min[1], max[2] - min[2])
    }
}

struct PlantAsset: Codable {
    let stage: GrowthStage
    let variant: String
    let file: String
    let thumbnail: String
    let bounds: AssetBounds
    let animation: String
    let bytes: Int
    let sha256: String
}

struct SpeciesManifest: Codable {
    let schemaVersion: Int
    let speciesId: String
    let assetVersion: String
    let format: String
    let units: String
    let authoringUpAxis: String
    let initialStage: GrowthStage
    let stageOrder: [GrowthStage]
    let variantIds: [String]
    let assets: [PlantAsset]
    var displayName: String { speciesId.capitalized }

    func validated() throws -> Self {
        guard schemaVersion == 1, format == "usdz", units == "metres",
              authoringUpAxis == "Z", initialStage == .sprout,
              stageOrder == GrowthStage.allCases, !variantIds.isEmpty,
              Set(variantIds).count == variantIds.count,
              assets.count == stageOrder.count * variantIds.count else {
            throw ForestError.invalidData("Unsupported asset manifest for \(speciesId).")
        }
        for stage in stageOrder {
            for variant in variantIds {
                guard assets.filter({ $0.stage == stage && $0.variant == variant }).count == 1 else {
                    throw ForestError.invalidData("Missing or duplicate \(speciesId) \(stage.rawValue) \(variant).")
                }
            }
        }
        for asset in assets {
            guard asset.bounds.min.count == 3, asset.bounds.max.count == 3,
                  zip(asset.bounds.min, asset.bounds.max).allSatisfy({ pair in pair.0.isFinite && pair.1.isFinite && pair.0 <= pair.1 }),
                  asset.bytes > 0, asset.sha256.count == 64 else {
                throw ForestError.invalidData("Invalid asset metadata for \(asset.file).")
            }
        }
        return self
    }
}

struct ResolvedPlantAsset {
    let manifest: SpeciesManifest
    let asset: PlantAsset
    let modelURL: URL
    let thumbnailURL: URL
    var key: String { "\(manifest.speciesId)/\(manifest.assetVersion)/\(asset.file)" }
}

/// Some RealityKit importers already convert USD up-axis. Correct only if
/// imported dimensions more closely match the authored Z-up dimensions.
/// Never normalize a stage to another height or adjust the ground anchor.
enum AssetOrientation {
    static func needsZUpCorrection(imported: SIMD3<Float>, authored: SIMD3<Float>) -> Bool {
        let yUp = SIMD3(authored.x, authored.z, authored.y)
        return simd_length(imported - authored) + 0.01 < simd_length(imported - yUp)
    }
}
