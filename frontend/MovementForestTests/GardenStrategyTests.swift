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
    func testGardenActionImpactRegressions() throws {
        let cases = try GardenStrategyContract.load().cases.map { ($0.name, $0.plants, $0.items, $0.context) }
        XCTAssertEqual(try GardenImpactChecks.run(cases), [])
    }
}

// Shared behavioral checks execute under XCTest and the portable Swift runner.
enum GardenImpactChecks {
    typealias Fixture = (name: String, plants: [APIOwnedPlant], items: [APIOwnedItem], context: APIStrategyContext)
    static func run(_ cases: [Fixture]) throws -> [String] {
        var failures: [String] = []
        func check(_ passed: Bool, _ message: String) { if !passed { failures.append(message) } }
        let context = cases.first { $0.name == "all_species" }!.context
        func plant(_ species: String) -> APIOwnedPlant { cases.first { $0.name == "adult_" + species }!.plants[0] }
        func item(_ name: String) -> APIOwnedItem { cases.first { $0.name == "item_" + name }!.items[0] }
        func copy(_ p: APIOwnedPlant, young: Bool = false) -> APIOwnedPlant {
            APIOwnedPlant(plantId: UUID(), speciesId: p.speciesId, variantId: p.variantId,
                growthMicroUnits: young ? "1" : p.growthMicroUnits, growthStage: young ? .young : p.growthStage,
                modelKey: p.modelKey, thumbnailKey: p.thumbnailKey, placement: nil, pinnedProfiles: p.pinnedProfiles,
                baseAttractionMicroUnits: p.baseAttractionMicroUnits, gardenSkills: p.gardenSkills, gameplayTags: p.gameplayTags)
        }
        func evaluate(_ plants: [APIOwnedPlant], _ items: [APIOwnedItem] = [], _ ctx: APIStrategyContext? = nil) throws -> GardenStrategyEvaluation {
            try GardenStrategyEvaluator.evaluate(plants: plants, items: items, context: ctx ?? context)
        }
        func rows(_ a: GardenStrategyEvaluation, _ b: GardenStrategyEvaluation) -> [GardenImpactRow] {
            GardenStrategyCopy.impact(from: a, to: b)
        }
        let empty = try evaluate([]), moon = plant("moonwillow"), moon2 = copy(moon), oak = plant("oak")
        let single = try evaluate([moon]), double = try evaluate([moon, moon2])
        check(rows(empty, single).contains { $0.text == "+ Sleeping Dew" && $0.direction == 1 }, "First mature plant adds its skill")
        check(rows(single, empty).contains { $0.text == "− Sleeping Dew" && $0.direction == -1 }, "Last mature plant loses its skill")
        check(rows(empty, single).filter { $0.id.hasPrefix("source/") }.allSatisfy { $0.detail.isEmpty } &&
            rows(single, empty).filter { $0.id.hasPrefix("source/") }.allSatisfy { $0.detail.isEmpty }, "Skill source rows omit redundant explanations")
        check(rows(single, double).count == 1 && rows(double, single).count == 1, "Equivalent duplicate source must stay quiet")
        let immature = try evaluate([copy(moon, young: true)])
        check(GardenSkillGroup.groups(in: immature).isEmpty, "Immature sources must not appear in Skills")
        check(!rows(empty, immature).contains { $0.id.hasPrefix("source/") }, "Immature placement must not announce a skill")
        let conditional = try evaluate([plant("moonbell")])
        check(GardenSkillGroup.groups(in: conditional).contains { $0.name == "Dewlit Path" }, "Unmet adult companion skill remains active")
        check(conditional.skillSummary.activeSkills.allSatisfy { $0.magnitude == "0.04" }, "Unmet companion retains only the base bonus")
        let companion = try evaluate([plant("moonbell"), copy(plant("heartleaf"), young: true)])
        check(rows(conditional, companion).contains { $0.text == "+4% water from steps (Dewlit Path)" },
            "An unmet adult skill strengthens when its companion arrives")
        let steps = try evaluate([plant("mirrorleaf")])
        check(GardenSkillGroup.groups(in: steps).contains { $0.name == "Sapphire Stride" }, "After-2000 skill remains active")
        let amber = plant("amberfan"), trees = (0..<5).map { _ in copy(oak) }
        // Amberfan is itself a tree and contributes to Golden Swirl's count.
        let three = try evaluate([amber] + Array(trees.prefix(2)))
        let four = try evaluate([amber] + Array(trees.prefix(3)))
        let five = try evaluate([amber] + Array(trees.prefix(4)))
        check(rows(three, four).contains { $0.text == "+2% water (Golden Swirl)" && $0.detail.contains("3 → 4") }, "Fourth tree strengthens Golden Swirl")
        check(rows(four, three).contains { $0.text == "−2% water (Golden Swirl)" && $0.direction == -1 }, "Fourth tree removal weakens Golden Swirl")
        check(!rows(five, four).contains { $0.text.contains("Golden Swirl") }, "Fifth tree removal leaves the capped skill unchanged")
        let dormantGolden = try evaluate([amber])
        check(GardenSkillGroup.groups(in: dormantGolden).contains { $0.name == "Golden Swirl" }, "Adult source remains active")
        let youngTree = copy(oak, young: true)
        let youngCounted = try evaluate([amber, youngTree])
        check(rows(dormantGolden, youngCounted).contains { $0.text == "+2% water (Golden Swirl)" }, "Immature recipients can strengthen an adult source")
        let lantern = plant("paper-lantern"), flower = copy(plant("bluebell"), young: true)
        let flowerBefore = try evaluate([lantern]), flowerAfter = try evaluate([lantern, flower])
        check(rows(flowerBefore, flowerAfter).count == 1 && rows(flowerAfter, flowerBefore).count == 1,
            "Receiving an existing flowering attraction bonus must produce only the attraction row")
        let flowerBonus = Decimal(string: flowerAfter.totalAttractionMicroUnits)! - Decimal(string: flowerBefore.totalAttractionMicroUnits)!
        check(flowerBonus > Decimal(string: flower.baseAttractionMicroUnits!)!, "Attraction preview includes the received flowering bonus")
        let fern = plant("silverlace-fern"), fungus = plant("starcap")
        let underBefore = try evaluate([fern, fungus]), underAfter = try evaluate([fern, fungus, oak])
        let underGroup = GardenSkillGroup.groups(in: underAfter).first { $0.name == "Understory Accord" }!
        check(underGroup.bonuses.contains { $0.contains("to ferns and fungi") }, "Skills explicitly label recipients")
        check(rows(underBefore, underAfter).contains { $0.text == "+2.5% water to ferns and fungi (Understory Accord)" }, "Companion change strengthens a retained subset bonus")
        let fernOnly = try evaluate([fern])
        check(rows(fernOnly, underBefore).count == 1 && rows(underBefore, fernOnly).count == 1,
            "Adding/removing a water recipient must not announce a changed skill")
        let oldNew = cases.first { $0.name == "old_and_new_sleeping_dew" }!.plants
        let bothVersions = try evaluate(oldNew), oldVersion = try evaluate([oldNew[0]])
        check(rows(bothVersions, oldVersion).contains { $0.text == "−4% water (Sleeping Dew)" }, "Removing a stronger source falls back to the remaining source")
        check(!rows(bothVersions, oldVersion).contains { $0.text == "− Sleeping Dew" }, "A fallback source keeps its skill active")
        let library = item("hollow-log-library")
        let libraryEmpty = try evaluate([], [library])
        check(GardenSkillGroup.groups(in: libraryEmpty).contains { $0.name == "Borrowed Wisdom" }, "Zero-valued item skill remains active")
        let libraryOne = try evaluate([oak], [library]), libraryTwo = try evaluate([oak, fungus], [library])
        check(rows(libraryOne, libraryTwo).contains { $0.text == "+1% water (Borrowed Wisdom)" }, "Plant placement strengthens an item's skill")
        check(rows(libraryTwo, libraryOne).contains { $0.text == "−1% water (Borrowed Wisdom)" }, "Plant storage weakens an item's skill")
        let harp = item("rainharp"), mailbox = item("snail-mailbox"), kite = item("cloud-shepherds-kite")
        let harpGarden = try evaluate([oak], [harp]), baseGarden = try evaluate([oak])
        check(rows(baseGarden, harpGarden).contains { $0.text == "+ Morning Rain" }, "First daily-water item adds its skill")
        check(rows(harpGarden, baseGarden).contains { $0.text == "− Morning Rain" }, "Last daily-water item removes its skill")
        var harp2 = harp
        let encoded = try JSONEncoder().encode(harp)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["ownedItemId"] = UUID().uuidString
        harp2 = try JSONDecoder().decode(APIOwnedItem.self, from: JSONSerialization.data(withJSONObject: object))
        let twoHarps = try evaluate([oak], [harp, harp2])
        check(rows(harpGarden, twoHarps).count == 1, "Duplicate items must not announce a skill or daily grant")
        let mailboxGarden = try evaluate([oak], [mailbox])
        check(rows(baseGarden, mailboxGarden).contains { $0.id == "capacity" && $0.direction == 1 }, "Item capacity gain is displayed")
        check(rows(mailboxGarden, baseGarden).contains { $0.id == "capacity" && $0.direction == -1 }, "Item capacity loss is displayed")
        let kiteGarden = try evaluate([oak], [kite])
        check(rows(baseGarden, kiteGarden).contains { $0.id.hasPrefix("source/") }, "Welcome-time item announces its first source")
        var cappedContext = context
        let capData = try JSONEncoder().encode(cappedContext)
        var capObject = try JSONSerialization.jsonObject(with: capData) as! [String: Any]
        var caps = capObject["caps"] as! [String: Any]
        caps["waterBonus"] = "0.01"
        capObject["caps"] = caps
        cappedContext = try JSONDecoder().decode(APIStrategyContext.self, from: JSONSerialization.data(withJSONObject: capObject))
        let cappedThree = try evaluate([amber] + Array(trees.prefix(2)), [], cappedContext)
        let cappedFour = try evaluate([amber] + Array(trees.prefix(3)), [], cappedContext)
        check(!rows(cappedThree, cappedFour).contains { $0.text.contains("Golden Swirl") }, "Fully capped changes must not claim extra effective water")
        caps["waterBonus"] = "0.07"
        capObject["caps"] = caps
        let partialContext = try JSONDecoder().decode(APIStrategyContext.self, from: JSONSerialization.data(withJSONObject: capObject))
        let partialThree = try evaluate([amber] + Array(trees.prefix(2)), [], partialContext)
        let partialFour = try evaluate([amber] + Array(trees.prefix(3)), [], partialContext)
        check(rows(partialThree, partialFour).contains { $0.text == "+1% water (Golden Swirl)" }, "A partial cap reports only the effective increase")
        var otherObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy(amber))) as! [String: Any]
        var otherRules = otherObject["gardenSkills"] as! [[String: Any]]
        otherRules[0]["id"] = "other_swirl"; otherRules[0]["name"] = "Other Swirl"; otherRules[0]["stackingGroup"] = "other_swirl"
        otherObject["gardenSkills"] = otherRules
        let other = try JSONDecoder().decode(APIOwnedPlant.self, from: JSONSerialization.data(withJSONObject: otherObject))
        caps["waterBonus"] = "0.1"; capObject["caps"] = caps
        let sharedContext = try JSONDecoder().decode(APIStrategyContext.self, from: JSONSerialization.data(withJSONObject: capObject))
        let sharedBefore = try evaluate([amber, other], [], sharedContext), sharedAfter = try evaluate([amber, other, oak], [], sharedContext)
        let sharedRows = rows(sharedBefore, sharedAfter).filter { $0.text.contains("water (") }
        check(sharedRows.count == 1 && sharedRows[0].text.hasPrefix("+2%"), "Simultaneous increases share the remaining cap exactly once")
        check(GardenStrategyCopy.delta("1000000", "1000001") == "+0.000001", "Attraction deltas retain micro-unit precision")
        check(GardenStrategyCopy.delta("1000001", "1000000") == "−0.000001", "Losses retain precision and minus sign")
        check(rows(three, four) == rows(three, four), "Impact row identities are stable")
        check(rows(four, four).count == 1 && rows(four, four)[0].direction == 0, "Move/rotation has no invented effects")
        return failures
    }
}
