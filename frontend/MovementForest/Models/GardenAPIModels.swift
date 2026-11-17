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
    var placement: APIPlacement?
    var clearanceRadius: Decimal? = nil
    var pinnedProfiles: APIPinnedProfiles? = nil
    var growthProgress: APIGrowthProgress? = nil
    var baseAttractionMicroUnits: String? = nil
    var contributesAttraction: Bool? = nil
    var gardenSkills: [APIGardenSkillDefinition]? = nil
    // Optional for older servers, receipts and cached snapshots.
    var metricMultipliers: [String: Decimal]? = nil
    var gameplayTags: [String]? = nil

    func rendered(catalogue: APICatalogue, assets: any AssetCatalogProviding) -> GardenPlant {
        let version = catalogue.variant(species: speciesId, variant: variantId)?.assetCatalogVersion
            ?? assets.species.first(where: { $0.speciesId == speciesId })?.assetVersion ?? "unavailable"
        // Resolve only exact delivered manifest keys. No arbitrary server path is opened.
        let manifest = assets.species.first { $0.speciesId == speciesId && $0.assetVersion == version }
        let asset = manifest?.assets.first { $0.stage == growthStage && $0.variant == variantId }
        let prefix = (catalogue.variant(species: speciesId, variant: variantId)?.assetCatalogKey)
            .map { ($0 as NSString).deletingLastPathComponent + "/" } ?? "assets/\(speciesId)/v1/"
        let matches = asset.map { modelKey == prefix + $0.file && thumbnailKey == prefix + $0.thumbnail } ?? false
        return GardenPlant(id: plantId, speciesId: speciesId, variantId: variantId,
                           assetVersion: matches ? version : "unavailable", growthStage: growthStage,
                           x: placement.map { NSDecimalNumber(decimal: $0.x).doubleValue } ?? 0,
                           y: placement.map { NSDecimalNumber(decimal: $0.y).doubleValue } ?? 0,
                           rotationDegrees: placement.map { NSDecimalNumber(decimal: $0.rotationDegrees).doubleValue } ?? 0)
    }
}

struct APIDailyItemWater: Codable, Equatable, Identifiable {
    var id: String { gameDate }
    let gameDate: String
    let water: String
    let plantCount: Int
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
    var plants: [APIOwnedPlant]
    var totalAttractionMicroUnits: String? = nil
    var skillSummary: APISkillSummary? = nil
    var strategyContext: APIStrategyContext? = nil
    var items: [APIOwnedItem]? = nil
    var dailyWater: [APIDailyItemWater]? = nil

    func rendered(catalogue: APICatalogue, assets: any AssetCatalogProviding) throws -> GardenSnapshot {
        guard coordinateUnit == "garden_unit", catalogue.coordinateUnit == coordinateUnit,
              catalogue.catalogVersion == catalogVersion, catalogue.gardenUnitMetres == gardenUnitMetres,
              gardenUnitMetres > 0, layoutVersion >= 0, stateVersion >= 0,
              Set(plants.map(\.id)).count == plants.count,
              plants.allSatisfy({ $0.placement?.gardenId == gardenId }),
              (items ?? []).allSatisfy({ $0.placement?.gardenId == gardenId }) else {
            throw ForestError.invalidData("The garden and catalogue do not describe the same layout. Refresh your garden.")
        }
        return try GardenSnapshot(gardenId: gardenId, title: "Your forest", isSample: false,
                                  width: NSDecimalNumber(decimal: width).doubleValue,
                                  depth: NSDecimalNumber(decimal: depth).doubleValue,
                                  gardenUnitMetres: NSDecimalNumber(decimal: gardenUnitMetres).doubleValue,
                                  catalogVersion: catalogVersion, layoutVersion: Int(layoutVersion),
                                  stateVersion: Int(stateVersion),
                                  plants: plants.map { $0.rendered(catalogue: catalogue, assets: assets) },
                                  items: (items ?? []).map { $0.rendered() }).validated()
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
    var capacity: APIInventoryCapacity? = nil
}

struct APIStageAsset: Codable, Equatable {
    let modelKey: String
    let thumbnailKey: String
}

struct APIVariant: Codable, Equatable {
    let variantId: String
    let displayName: String
    var assetCatalogKey: String? = nil
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
              let value = plant.clearanceRadius ?? species.first(where: { $0.speciesId == plant.speciesId })?.clearanceRadius else {
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
    var gardenEffects: [APIGardenSkillDefinition]? = nil
}

struct APIGardenSkillDefinition: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
    let minimumStage: String
    var componentVersion: Int? = nil
    var stepBand: String? = nil
    var system: String? = nil
    var scope: String? = nil
    var metric: String? = nil
    var target: String? = nil
    var recipients: APIStrategySelector? = nil
    var condition: APIStrategyCondition? = nil
    var operation: String? = nil
    var magnitude: APIStrategyMagnitude? = nil
    var stackingGroup: String? = nil
    var stackingRule: String? = nil
}

struct APISkillSummary: Codable, Equatable {
    let policyVersion: String
    let caps: Caps
    let activeSkills: [Effect]
    let growthFactors: [GrowthFactors]

    struct Caps: Codable, Equatable {
        let activityBonus: String
        let waterBonus: String
        var plantAttractionBonus: String? = nil
        var gardenAttractionBonus: String? = nil
        var totalAttractionBonus: String? = nil
        var flatAttractionPoints: String? = nil
        var flatAttractionBaseFraction: String? = nil
        var capacityBonus: String? = nil
        var flatCapacity: Int? = nil

        var description: String {
            func percent(_ value: String) -> String {
                guard let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return "Unavailable" }
                return (amount * 100).formatted(.number.precision(.fractionLength(0...2))) + "%"
            }
            return "Maximum activity bonus +\(percent(activityBonus)). Maximum water bonus +\(percent(waterBonus))."
        }
    }

    struct Effect: Codable, Equatable, Identifiable {
        var id: String { "\(system).\(scope).\(metric ?? "").\(stackingGroup).\(profileId).\(profileVersion).\(skillId)" }
        let skillId: String
        let name: String
        let description: String
        let system: String
        let scope: String
        let metric: String?
        let operation: String
        let magnitude: String
        let stackingGroup: String
        var stepBand: String? = nil
        var sourcePlantId: UUID? = nil
        var sourceItemId: UUID? = nil
        var sourceKind: String? = nil
        var eligibleSourceItemIds: [UUID]? = nil
        let profileId: String
        let profileVersion: Int
        let eligibleSourcePlantIds: [UUID]
        let recipientPlantIds: [UUID]

        enum CodingKeys: String, CodingKey {
            case skillId = "id"
            case name, description, system, scope, metric, operation, magnitude, stackingGroup
            case sourcePlantId, profileId, profileVersion, eligibleSourcePlantIds, recipientPlantIds
            case sourceItemId, sourceKind, eligibleSourceItemIds, stepBand
        }

        var bonusText: String {
            guard let amount = Decimal(string: magnitude, locale: Locale(identifier: "en_US_POSIX")) else { return "Unavailable" }
            let value = operation == "percent" ? (amount * 100).formatted(.number.precision(.fractionLength(0...2))) + "%" : amount.formatted()
            let destination: String
            switch scope {
            case "water": destination = "water"
            case "activity":
                switch metric {
                case "steps":
                    destination = stepBand == "first_2000" ? "water from the first 2,000 steps" :
                        stepBand == "after_2000" ? "water from steps after 2,000" : "water from steps"
                case "walking_running_distance_km": destination = "water from walking and running"
                case "active_energy_kcal": destination = "water from active energy"
                case "flights_climbed": destination = "water from flights climbed"
                default:
                    if let metric = metric, metric.hasPrefix("workout_minutes.") {
                        destination = "water from " + metric.replacingOccurrences(of: "workout_minutes.", with: "").replacingOccurrences(of: "_", with: " ") + " workouts"
                    } else { destination = "activity water" }
                }
            case "offline_capacity": destination = "storage"
            case "welcome_duration": destination = "welcome time"
            case "daily_water": destination = "daily water per plant"
            default: destination = "attraction"
            }
            return "+\(value) \(destination)"
        }
    }

    struct GrowthFactors: Codable, Equatable {
        let plantId: UUID
        let waterFactor: String
        let activityFactors: [String: String]
        let waterCapReached: Bool
        let activityCapReached: [String: Bool]
    }

    var waterHeadline: String? {
        let factors = Set(growthFactors.map(\.waterFactor))
        guard factors.count == 1, let value = factors.first,
              let factor = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), factor > 1 else { return nil }
        return "Water +\(((factor - 1) * 100).formatted(.number.precision(.fractionLength(0...2))))%"
    }

    var capReached: Bool {
        growthFactors.contains { $0.waterCapReached || $0.activityCapReached.values.contains(true) }
    }
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
    var itemActions: [ItemEditAction]? = nil
    var expectedStrategyFingerprint: String? = nil

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


extension Array where Element == APIGardenSkillDefinition {
    var uniqueSkills: [APIGardenSkillDefinition] {
        var seen = Set<String>()
        return filter { seen.insert($0.name).inserted }
    }
}


extension Array where Element == APISkillSummary.Effect {
    var uniqueSkills: [APISkillSummary.Effect] {
        var seen = Set<String>()
        return filter { seen.insert($0.name).inserted }
    }
}
