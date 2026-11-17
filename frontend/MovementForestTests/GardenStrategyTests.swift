import XCTest
@testable import MovementForest

struct GardenStrategyContract: Decodable {
    let cases: [Case]
    struct Case: Decodable {
        let name: String
        let plants: [APIOwnedPlant]
        let items: [APIOwnedItem]
        let context: APIStrategyContext
        let expectedSignature: String
    }
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "garden-strategy-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

final class GardenStrategyTests: XCTestCase {
    func testAllBackendReferenceCasesMatchNativePredictions() throws {
        let contract = try GardenStrategyContract.load()
        XCTAssertEqual(contract.cases.count, 87)
        for example in contract.cases {
            let value = try GardenStrategyEvaluator.evaluate(plants: example.plants, items: example.items, context: example.context)
            XCTAssertEqual(value.signature, example.expectedSignature, example.name)
            let reversed = try GardenStrategyEvaluator.evaluate(plants: Array(example.plants.reversed()), items: Array(example.items.reversed()), context: example.context)
            XCTAssertEqual(value.signature, reversed.signature, "Input order: " + example.name)
        }
    }
    func testIncompleteRulesNeverInventEffects() throws {
        let example = try XCTUnwrap(GardenStrategyContract.load().cases.first { $0.name == "adult_moonwillow" })
        var plant = try XCTUnwrap(example.plants.first)
        plant.gardenSkills = nil
        XCTAssertThrowsError(try GardenStrategyEvaluator.evaluate(plants: [plant], items: [], context: example.context))
    }
    func testInactiveAdultAppearanceCannotActivateASkill() throws {
        let example = try XCTUnwrap(GardenStrategyContract.load().cases.first { $0.name == "adult_moonwillow" })
        let plant = try XCTUnwrap(example.plants.first)
        let young = APIOwnedPlant(plantId: plant.id, speciesId: plant.speciesId, variantId: plant.variantId,
            growthMicroUnits: "1", growthStage: .young, modelKey: plant.modelKey, thumbnailKey: plant.thumbnailKey,
            placement: nil, pinnedProfiles: plant.pinnedProfiles, baseAttractionMicroUnits: "1", gardenSkills: plant.gardenSkills,
            gameplayTags: plant.gameplayTags)
        let value = try GardenStrategyEvaluator.evaluate(plants: [young], items: [], context: example.context)
        XCTAssertTrue(value.skillSummary.activeSkills.isEmpty)
    }
    func testSkillGroupsRetainEveryAfterglowComponent() throws {
        let example = try XCTUnwrap(GardenStrategyContract.load().cases.first { $0.name == "all_species" })
        let value = try GardenStrategyEvaluator.evaluate(plants: example.plants, items: example.items, context: example.context)
        let group = try XCTUnwrap(GardenSkillGroup.groups(value.skillSummary).first { $0.name == "Afterglow" })
        XCTAssertTrue(group.effects.contains { $0.scope == "activity" })
        XCTAssertTrue(group.effects.contains { $0.scope == "offline_capacity" })
    }
}
