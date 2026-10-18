import Foundation
import simd

enum GrowthStage: String, Codable, CaseIterable, Identifiable {
    case sprout, seedling, young, adult
    var id: String { rawValue }
    var title: String { self == .young ? "Young plant" : rawValue.capitalized }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct GardenPlant: Codable, Identifiable, Equatable {
    let id: UUID
    let speciesId: String
    let variantId: String
    let assetVersion: String
    var growthStage: GrowthStage
    var x: Double
    var y: Double
    var rotationDegrees: Double
}

struct GardenSnapshot: Codable, Equatable {
    let gardenId: UUID
    let title: String
    let isSample: Bool
    let width: Double
    let depth: Double
    let gardenUnitMetres: Double
    let catalogVersion: String
    let layoutVersion: Int
    let stateVersion: Int
    var plants: [GardenPlant]

    func validated() throws -> Self {
        guard width.isFinite, depth.isFinite, gardenUnitMetres.isFinite,
              width > 0, depth > 0, gardenUnitMetres > 0,
              Set(plants.map(\.id)).count == plants.count else {
            throw ForestError.invalidData("The garden has invalid dimensions or duplicate plant IDs.")
        }
        for plant in plants {
            guard plant.x.isFinite, plant.y.isFinite, plant.rotationDegrees.isFinite,
                  (0...width).contains(plant.x), (0...depth).contains(plant.y),
                  (0..<360).contains(plant.rotationDegrees) else {
                throw ForestError.invalidData("A plant has an invalid ground position or rotation.")
            }
        }
        return self
    }
}

enum ForestError: LocalizedError {
    case missingResource(String), invalidData(String), assetLoad(String)
    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Missing bundled resource: \(name). Restore the asset packages and rebuild the app."
        case .invalidData(let message), .assetLoad(let message): return message
        }
    }
}

/// Board-local X/Y are horizontal. The scene uses metres and Y-up.
enum GardenCoordinates {
    static func world(x: Double, y: Double, unitMetres: Double) -> SIMD3<Float> {
        SIMD3(Float(x * unitMetres), 0, Float(y * unitMetres))
    }

    static func groundIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                   width: Double, depth: Double, unitMetres: Double) -> SIMD2<Double>? {
        guard abs(direction.y) > 0.00001, unitMetres > 0 else { return nil }
        let t = -origin.y / direction.y
        guard t >= 0 else { return nil }
        let point = origin + direction * t
        let x = Double(point.x) / unitMetres
        let y = Double(point.z) / unitMetres
        guard x.isFinite, y.isFinite, (0...width).contains(x), (0...depth).contains(y) else { return nil }
        return SIMD2(x, y)
    }
}
