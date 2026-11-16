import Foundation
import RealityKit
import XCTest
@testable import MovementForest

private struct ItemRotationContract: Decodable {
    let summary: APICollectionSummary
    let inventory: APIItemInventory
    let garden: APIGarden
    let afterDailyWater: APIGarden
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "item-rotations-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@MainActor
final class ItemRotationTests: XCTestCase {
    func testCountdownUsesMonotonicElapsedAndConservativeLatency() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let rotation = APIShopRotation(serverNow: start, shopTimezone: "UTC", rotationId: "test",
            startsAt: start, endsAt: start.addingTimeInterval(100))
        let clock = ShopCountdown(rotation: rotation, sent: 10, received: 12)
        XCTAssertEqual(clock.remaining(at: 12), 98)
        XCTAssertEqual(clock.remaining(at: 62), 48)
        XCTAssertEqual(clock.remaining(at: 112), 0)
        // No device wall time or display timezone is an input to availability.
        XCTAssertEqual(clock.remaining(at: 11), 98)
    }

    func testRealHTTPItemSourcesAndDailyWaterDecode() throws {
        let value = try ItemRotationContract.load()
        XCTAssertEqual(value.inventory.items.count, 15)
        XCTAssertEqual(Set(value.inventory.items.map(\.itemId)).count, 15)
        let skills = try XCTUnwrap(value.garden.skillSummary).activeSkills
        XCTAssertEqual(Set(skills.map(\.skillId)).count, 8)
        XCTAssertTrue(skills.allSatisfy { $0.sourceItemId != nil && $0.sourcePlantId == nil })
        XCTAssertTrue(skills.contains { $0.scope == "welcome_duration" && $0.magnitude == "0.2" })
        XCTAssertEqual(value.afterDailyWater.dailyWater?.first?.water, "2.5")
        XCTAssertEqual(value.afterDailyWater.plants.first?.growthMicroUnits, "2500000")
        XCTAssertEqual(value.summary.itemOffers?.filter { $0.rarity == "common" }.count, 3)
        XCTAssertEqual(value.summary.shop?.shopTimezone, "UTC")
        XCTAssertTrue(value.summary.itemOffers?.allSatisfy { $0.endsAt == value.summary.shop?.endsAt } == true)
    }

    func testAllFifteenBundledModelsImportAndFiveHavePlayableLoops() async throws {
        let value = try ItemRotationContract.load(), loader = PlantModelLoader()
        var animated = 0
        func clips(_ entity: Entity) -> Int {
            if !entity.availableAnimations.isEmpty { return 1 }
            return entity.children.reduce(0) { $0 + clips($1) }
        }
        for item in value.inventory.items {
            let asset = try BundledItemAssets.resolve(item.rendered())
            let loaded = try await loader.load(asset)
            XCTAssertFalse(loaded.entity.children.isEmpty, item.itemId)
            if asset.animated {
                animated += 1
                XCTAssertGreaterThan(clips(loaded.entity), 0, item.itemId)
            }
        }
        XCTAssertEqual(animated, 5)
    }
}
