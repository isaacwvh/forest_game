import Foundation

enum DevelopmentScene: String, CaseIterable, Identifiable {
    case single, mixed, mature, moonwillowStress, sprouts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "Single oak"
        case .mixed: return "15 mixed stages"
        case .mature: return "15 mature trees"
        case .moonwillowStress: return "15 adult Moonwillows"
        case .sprouts: return "15 sprouts"
        }
    }

    func garden() -> GardenSnapshot {
        let positions: [(Double, Double)] = [
            (1.2, 1.3), (3.1, 1.1), (5.0, 1.5), (7.0, 1.2), (8.8, 1.4),
            (1.4, 4.3), (3.4, 4.6), (5.2, 4.1), (7.1, 4.5), (8.7, 4.2),
            (1.1, 7.8), (3.0, 8.2), (5.1, 7.9), (7.2, 8.3), (8.8, 7.8)
        ]
        let count = self == .single ? 1 : 15
        let plants = (0..<count).map { i -> GardenPlant in
            let moon = self == .moonwillowStress || (self != .single && i % 3 == 1)
            let stage: GrowthStage = self == .sprouts ? .sprout :
                (self == .mixed ? GrowthStage.allCases[i % 4] : .adult)
            // Stable identities make repeatable scene comparison possible.
            let id = UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", i + 1))!
            return GardenPlant(id: id, speciesId: moon ? "moonwillow" : "oak",
                               variantId: moon ? (i % 2 == 0 ? "golden" : "standard") : ["standard", "blue", "vined"][i % 3],
                               assetVersion: "1.0.0", growthStage: stage,
                               x: self == .single ? 5 : positions[i].0,
                               y: self == .single ? 5 : positions[i].1,
                               rotationDegrees: Double((i * 47) % 360))
        }
        return GardenSnapshot(gardenId: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                              title: title, isSample: true, width: 10, depth: 10, gardenUnitMetres: 1,
                              catalogVersion: "development-1", layoutVersion: 1, stateVersion: 1, plants: plants)
    }
}
