import Foundation

struct APIProfile: Codable, Equatable {
    let userId: UUID
    let username: String
    let displayName: String
    let gameTimezone: String
}

struct APIPlacement: Codable, Equatable {
    let gardenId: UUID
    let x: Decimal
    let y: Decimal
    let rotationDegrees: Decimal
}

struct APIOwnedPlant: Codable, Identifiable, Equatable {
    var id: UUID { plantId }
    let plantId: UUID
    let speciesId: String
    let variantId: String
    let growthMicroUnits: String
    let growthStage: GrowthStage
    let modelKey: String
    let thumbnailKey: String
    let placement: APIPlacement?
    var pinnedProfiles: APIPinnedProfiles? = nil
    var growthProgress: APIGrowthProgress? = nil
    var baseAttractionMicroUnits: String? = nil
    var contributesAttraction: Bool? = nil

    func rendered(catalogue: APICatalogue, assets: any AssetCatalogProviding) -> GardenPlant {
        let version = catalogue.variant(species: speciesId, variant: variantId)?.assetCatalogVersion
            ?? assets.species.first(where: { $0.speciesId == speciesId })?.assetVersion ?? "unavailable"
        // Resolve only exact delivered manifest keys. No arbitrary server path is opened.
        let manifest = assets.species.first { $0.speciesId == speciesId && $0.assetVersion == version }
        let asset = manifest?.assets.first { $0.stage == growthStage && $0.variant == variantId }
        let prefix = "assets/\(speciesId)/v1/"
        let matches = asset.map { modelKey == prefix + $0.file && thumbnailKey == prefix + $0.thumbnail } ?? false
        return GardenPlant(id: plantId, speciesId: speciesId, variantId: variantId,
                           assetVersion: matches ? version : "unavailable", growthStage: growthStage,
                           x: placement.map { NSDecimalNumber(decimal: $0.x).doubleValue } ?? 0,
                           y: placement.map { NSDecimalNumber(decimal: $0.y).doubleValue } ?? 0,
                           rotationDegrees: placement.map { NSDecimalNumber(decimal: $0.rotationDegrees).doubleValue } ?? 0)
    }
}

struct APIGarden: Codable, Equatable {
    let gardenId: UUID
    let width: Decimal
    let depth: Decimal
    let coordinateUnit: String
    let gardenUnitMetres: Decimal
    let catalogVersion: String
    let layoutVersion: Int64
    let stateVersion: Int64
    let plants: [APIOwnedPlant]
    var totalAttractionMicroUnits: String? = nil

    func rendered(catalogue: APICatalogue, assets: any AssetCatalogProviding) throws -> GardenSnapshot {
        guard coordinateUnit == "garden_unit", catalogue.coordinateUnit == coordinateUnit,
              catalogue.catalogVersion == catalogVersion, catalogue.gardenUnitMetres == gardenUnitMetres,
              gardenUnitMetres > 0, layoutVersion >= 0, stateVersion >= 0,
              Set(plants.map(\.id)).count == plants.count,
              plants.allSatisfy({ $0.placement?.gardenId == gardenId }) else {
            throw ForestError.invalidData("The garden and catalogue do not describe the same layout. Refresh your garden.")
        }
        return try GardenSnapshot(gardenId: gardenId, title: "Your forest", isSample: false,
                                  width: NSDecimalNumber(decimal: width).doubleValue,
                                  depth: NSDecimalNumber(decimal: depth).doubleValue,
                                  gardenUnitMetres: NSDecimalNumber(decimal: gardenUnitMetres).doubleValue,
                                  catalogVersion: catalogVersion, layoutVersion: Int(layoutVersion),
                                  stateVersion: Int(stateVersion),
                                  plants: plants.map { $0.rendered(catalogue: catalogue, assets: assets) }).validated()
    }
}

struct APIProfileReference: Codable, Equatable {
    let id: String
    let version: Int
}

struct APIPinnedProfiles: Codable, Equatable {
    let growth: APIProfileReference
    let behaviour: APIProfileReference
    let attraction: APIProfileReference
}

struct APIGrowthProgress: Codable, Equatable {
    let stageStartMicroUnits: String
    let nextStageMicroUnits: String?
    let maximumGrowthMicroUnits: String

    func fraction(growth: String) -> Double? {
        guard let current = ExactAmount.integer(growth),
              let start = ExactAmount.integer(stageStartMicroUnits),
              let maximum = ExactAmount.integer(maximumGrowthMicroUnits),
              current >= start, current <= maximum else { return nil }
        guard let nextValue = nextStageMicroUnits else { return current == maximum ? 1 : nil }
        guard let next = ExactAmount.integer(nextValue), next > start, next <= maximum else { return nil }
        return min(1, max(0, NSDecimalNumber(decimal: (current - start) / (next - start)).doubleValue))
    }
}

enum ExactAmount {
    static func integer(_ value: String) -> Decimal? {
        guard !value.isEmpty, value.count <= 19, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              number <= Decimal(Int64.max) else { return nil }
        return number
    }
    static func water(_ value: String) -> String {
        guard let amount = integer(value) else { return "Unavailable" }
        return (amount / 1_000_000).formatted(.number.precision(.fractionLength(0...6)))
    }
}

struct APIInventory: Codable {
    let plants: [APIOwnedPlant]
    let nextCursor: UUID?
}

struct APIStageAsset: Codable, Equatable {
    let modelKey: String
    let thumbnailKey: String
}

struct APIVariant: Codable, Equatable {
    let variantId: String
    let displayName: String
    let assetCatalogVersion: String
    let stages: [String: APIStageAsset]
    var description: String? = nil
    var rarity: String? = nil
    var profileOverrides: [String: APIProfileReference?]? = nil
}

struct APISpecies: Codable, Equatable {
    let speciesId: String
    let displayName: String
    let clearanceRadius: Decimal
    let variants: [APIVariant]
    var description: String? = nil
    var defaultProfiles: APIPinnedProfiles? = nil
    var rarity: String? = nil
}

struct APICatalogue: Codable, Equatable {
    let catalogVersion: String
    let isFixture: Bool
    let coordinateUnit: String
    let gardenUnitMetres: Decimal
    let coordinateDecimalPlaces: Int
    let rotationDecimalPlaces: Int
    let species: [APISpecies]
    var profiles: [String: [APICatalogueProfile]]? = nil

    func variant(species id: String, variant: String) -> APIVariant? {
        species.first { $0.speciesId == id }?.variants.first { $0.variantId == variant }
    }

    func radius(for plant: APIOwnedPlant) throws -> Int64 {
        guard coordinateUnit == "garden_unit", coordinateDecimalPlaces == 3, rotationDecimalPlaces == 2,
              let value = species.first(where: { $0.speciesId == plant.speciesId })?.clearanceRadius else {
            throw ForestError.invalidData("Placement rules are unavailable for this plant. Refresh the catalogue.")
        }
        let radius = try PlacementGeometry.units(value)
        guard radius > 0 else { throw ForestError.invalidData("The catalogue contains an invalid plant radius.") }
        return radius
    }
}

struct APICatalogueProfile: Codable, Equatable {
    let id: String
    let version: Int
    var thresholdsMicroUnits: [String: String]? = nil
    var maximumGrowthMicroUnits: String? = nil
    var metricMultipliers: [String: Decimal]? = nil
    var stageAttractionMicroUnits: [String: String]? = nil
    var gameplayTags: [String]? = nil
}

enum GardenEditKind: String, Codable { case plant, move, rotate, store }

struct GardenEditAction: Codable, Equatable {
    let action: GardenEditKind
    let plantId: UUID
    var x: Decimal?
    var y: Decimal?
    var rotationDegrees: Decimal?
}

struct GardenEditRequest: Codable, Equatable {
    let requestId: UUID
    let expectedLayoutVersion: Int64
    let catalogVersion: String
    let actions: [GardenEditAction]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct GardenEditResult: Codable {
    let requestId: UUID
    let garden: APIGarden
    let updatedPlants: [APIOwnedPlant]
}
