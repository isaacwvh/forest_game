import XCTest
import Foundation
import SwiftUI
import UIKit
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
    @MainActor
    func testCompactCatalogMetricReservesASeparateSingleLineForTheWholeNumber() {
        func height(_ value: String) -> CGFloat {
            let host = UIHostingController(rootView:
                JournalMetric(title: "Cumulative water", value: value, explanation: "", metric: "water", compact: true)
                    .environment(\.dynamicTypeSize, .large))
            return host.sizeThatFits(in: CGSize(width: 74, height: 1000)).height
        }
        let baseline = height("0")
        let lineHeight = UIFont.preferredFont(forTextStyle: .caption2,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight
        XCTAssertGreaterThan(baseline, 44, "The number needs its own row below the 44-point icon target")
        XCTAssertLessThanOrEqual(baseline, 44 + ceil(lineHeight) + 4)
        for value in ["1000", "1,000", "1000.1"] {
            XCTAssertEqual(height(value), baseline, accuracy: 1, "\(value) must stay on one line in an 80-point stage cell")
        }
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
    @MainActor
    func testPackCardsKeepEqualHeightsForLongNamesAndPrices() {
        func size(_ name: String, price: String, textSize: DynamicTypeSize, width: CGFloat) -> CGSize {
            let host = UIHostingController(rootView:
                CollectionPackCard(packID: "generic", name: name, price: price, infoID: "test.info", inspect: {}) {
                    Text("Purchase").frame(maxWidth: .infinity, minHeight: 44)
                }.environment(\.dynamicTypeSize, textSize))
            return host.sizeThatFits(in: CGSize(width: width, height: 2000))
        }
        for textSize: DynamicTypeSize in [.large, .xxxLarge, .accessibility3] {
            let width: CGFloat = textSize.isAccessibilitySize ? 288 : 142
            let short = size("Woodland", price: "5", textSize: textSize, width: width)
            let long = size("Moonwillow woodland collection pack", price: "1000000000", textSize: textSize, width: width)
            XCTAssertEqual(long.height, short.height, accuracy: 1, "Names/prices must not change card height")
            XCTAssertLessThanOrEqual(long.width, width + 1)
            XCTAssertGreaterThan(short.height, 200)
        }
    }
    @MainActor
    func testSimpleVariantOddsFitNarrowScreensWithLongNames() {
        let odds = SpeciesDrawOdds(speciesId: "moonwillow", rarity: "epic", withinRarity: 0.5, overall: 0.0000001,
                                  variants: [VariantDrawOdds(variantId: "standard", conditional: 1, overall: 0.0000001)])
        for textSize: DynamicTypeSize in [.large, .accessibility3] {
            let host = UIHostingController(rootView:
                CollectionOddsDetails(odds: odds).environment(\.dynamicTypeSize, textSize))
            let size = host.sizeThatFits(in: CGSize(width: 232, height: 2000))
            XCTAssertLessThanOrEqual(size.width, 233)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.height, 0)
        }
    }
    @MainActor
    func testCollectionSummaryFitsNarrowScreensWithLargeTextAndOverLimitCounts() {
        let capacity = APIInventoryCapacity(ownedPlants: 125, plantedPlants: 25, storedPlants: 100,
                                           plantLimit: 50, plantedLimit: 20, unopenedPacks: 110, packLimit: 50)
        for textSize: DynamicTypeSize in [.large, .accessibility3] {
            for balance: String? in [nil, "0", "9223372036854775807"] {
                let host = UIHostingController(rootView:
                    CollectionWalletSummary(balance: balance, capacity: capacity, showsPlants: true, cached: true)
                        .environment(\.dynamicTypeSize, textSize))
                let size = host.sizeThatFits(in: CGSize(width: 288, height: 2000))
                XCTAssertLessThanOrEqual(size.width, 289)
                XCTAssertTrue(size.height.isFinite)
                XCTAssertGreaterThan(size.height, 44)
            }
        }
    }
}
