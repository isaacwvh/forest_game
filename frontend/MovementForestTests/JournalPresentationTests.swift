import XCTest
import Foundation
@testable import MovementForest

final class JournalPresentationTests: XCTestCase {
    private func copy(stage: GrowthStage = .seedling, growth: String = "250000000",
                      start: String = "100000000", next: String? = "400000000") -> APIOwnedPlant {
        APIOwnedPlant(plantId: UUID(), speciesId: "oak", variantId: "blue",
            growthMicroUnits: growth, growthStage: stage, modelKey: "", thumbnailKey: "", placement: nil,
            growthProgress: APIGrowthProgress(stageStartMicroUnits: start, nextStageMicroUnits: next,
                                            maximumGrowthMicroUnits: "1000000000"))
    }
    func testCompactProgressIsRelativeToThePinnedStageAndKeepsExactRemainingAmount() {
        let display = JournalGrowthSummary(plant: copy())
        XCTAssertEqual(display.fraction, 0.5)
        XCTAssertEqual(display.remaining, "150")
        XCTAssertEqual(display.nextStage, "Young")
        XCTAssertFalse(display.fullyGrown)
        let olderProfile = JournalGrowthSummary(plant: copy(growth: "240000000", start: "40000000", next: "840000000"))
        XCTAssertEqual(olderProfile.fraction, 0.25)
        XCTAssertEqual(olderProfile.remaining, "600")
    }
    func testUnavailableProgressDoesNotPretendToBeAnEmptyBar() {
        let display = JournalGrowthSummary(plant: copy(growth: "invalid"))
        XCTAssertNil(display.fraction); XCTAssertNil(display.remaining)
        XCTAssertEqual(display.caption, "Growth unavailable")
        var noProfile = copy(); noProfile.growthProgress = nil
        XCTAssertNil(JournalGrowthSummary(plant: noProfile).fraction)
    }
    func testAdultUsesTerminalStateWithoutInventingANextStage() {
        let display = JournalGrowthSummary(plant: copy(stage: .adult, growth: "1000000000", start: "1000000000", next: nil))
        XCTAssertTrue(display.fullyGrown)
        XCTAssertNil(display.remaining); XCTAssertNil(display.nextStage)
        XCTAssertEqual(display.caption, "Fully grown")
    }
    func testZeroRemainingAndFractionalWaterAreNotRoundedAway() {
        let threshold = JournalGrowthSummary(plant: copy(growth: "400000000"))
        XCTAssertEqual(threshold.remaining, "0")
        let fractional = JournalGrowthSummary(plant: copy(growth: "399999999"))
        XCTAssertEqual(fractional.remaining, ExactAmount.water("1"))
        XCTAssertNotEqual(fractional.remaining, "0")
        XCTAssertEqual(fractional.displayRemaining, JournalAmount.water("1"))
    }
    func testWaterDisplayRoundsWithoutChangingExactAmounts() {
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(JournalAmount.water("541157600", locale: locale), "541.2")
        XCTAssertEqual(JournalAmount.water("39308141", locale: locale), "39.3")
        XCTAssertEqual(JournalAmount.water("150000", locale: locale), "0.2")
        XCTAssertEqual(JournalAmount.water("100000000", locale: locale), "100")
        XCTAssertEqual(JournalAmount.water("0", locale: locale), "0")
        XCTAssertEqual(JournalAmount.water("1", locale: locale), "<0.1")
        XCTAssertEqual(JournalAmount.water("invalid", locale: locale), "Unavailable")
        let display = JournalGrowthSummary(plant: copy(growth: "360691859"))
        XCTAssertEqual(display.remaining, ExactAmount.water("39308141"))
        XCTAssertEqual(display.displayRemaining, JournalAmount.water("39308141"))
        XCTAssertEqual(display.caption, "\(JournalAmount.water("39308141")) to Young")
    }
    func testCatalogDescriptionsReplaceOnlyLegacyPlaceholderOrMissingCopy() {
        var oak = APISpecies(speciesId: "oak", displayName: "Oak", clearanceRadius: 0.9, variants: [])
        XCTAssertEqual(CatalogSpeciesCopy.description(for: oak),
                       "Broad-crowned oak with sculpted branches, grouped foliage and softly veined early leaves.")
        oak.description = "Movement Forest initial collection."
        XCTAssertEqual(CatalogSpeciesCopy.description(for: oak),
                       "Broad-crowned oak with sculpted branches, grouped foliage and softly veined early leaves.")
        oak.description = "An authored server description."
        XCTAssertEqual(CatalogSpeciesCopy.description(for: oak), "An authored server description.")
        let unknown = APISpecies(speciesId: "unknown", displayName: "Unknown", clearanceRadius: 1, variants: [])
        XCTAssertNil(CatalogSpeciesCopy.description(for: unknown))
    }
}
