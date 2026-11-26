import XCTest
import Foundation
import SwiftUI
import UIKit
@testable import MovementForest

final class JournalPresentationTests: XCTestCase {
    private func makePlant(stage: GrowthStage = .seedling, growth: String = "250000000",
                      start: String = "100000000", next: String? = "400000000") -> APIOwnedPlant {
        APIOwnedPlant(plantId: UUID(), speciesId: "oak", variantId: "blue",
            growthMicroUnits: growth, growthStage: stage, modelKey: "", thumbnailKey: "", placement: nil,
            growthProgress: APIGrowthProgress(stageStartMicroUnits: start, nextStageMicroUnits: next,
                                            maximumGrowthMicroUnits: "1000000000"))
    }
    func testCompactProgressIsRelativeToThePinnedStageAndKeepsExactRemainingAmount() {
        let display = JournalGrowthSummary(plant: makePlant())
        XCTAssertEqual(display.fraction, 0.5)
        XCTAssertEqual(display.remaining, "150")
        XCTAssertEqual(display.nextStage, "Young")
        XCTAssertFalse(display.fullyGrown)
        let olderProfile = JournalGrowthSummary(plant: makePlant(growth: "240000000", start: "40000000", next: "840000000"))
        XCTAssertEqual(olderProfile.fraction, 0.25)
        XCTAssertEqual(olderProfile.remaining, "600")
    }
    func testUnavailableProgressDoesNotPretendToBeAnEmptyBar() {
        let display = JournalGrowthSummary(plant: makePlant(growth: "invalid"))
        XCTAssertNil(display.fraction); XCTAssertNil(display.remaining)
        XCTAssertEqual(display.caption, "Growth unavailable")
        var noProfile = makePlant(); noProfile.growthProgress = nil
        XCTAssertNil(JournalGrowthSummary(plant: noProfile).fraction)
    }
    func testAdultUsesTerminalStateWithoutInventingANextStage() {
        let display = JournalGrowthSummary(plant: makePlant(stage: .adult, growth: "1000000000", start: "1000000000", next: nil))
        XCTAssertTrue(display.fullyGrown)
        XCTAssertNil(display.remaining); XCTAssertNil(display.nextStage)
        XCTAssertEqual(display.caption, "Fully grown")
    }
    func testZeroRemainingAndFractionalWaterAreNotRoundedAway() {
        let threshold = JournalGrowthSummary(plant: makePlant(growth: "400000000"))
        XCTAssertEqual(threshold.remaining, "0")
        let fractional = JournalGrowthSummary(plant: makePlant(growth: "399999999"))
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
        let display = JournalGrowthSummary(plant: makePlant(growth: "360691859"))
        XCTAssertEqual(display.remaining, ExactAmount.water("39308141"))
        XCTAssertEqual(display.displayRemaining, JournalAmount.water("39308141"))
        XCTAssertEqual(display.caption, "\(JournalAmount.water("39308141")) to Young")
    }
    func testFullProfileUsesCumulativeWaterWhileTheBarTracksThePinnedStage() {
        let sprout = JournalGrowthSummary(plant: makePlant(stage: .sprout, growth: "100000",
                                                     start: "0", next: "45000000"))
        XCTAssertEqual(sprout.waterProgress,
                       "\(JournalAmount.water("100000")) / \(JournalAmount.water("45000000"))")
        XCTAssertEqual(sprout.fraction ?? -1, 0.1 / 45, accuracy: 0.000001)
        XCTAssertEqual(sprout.nextStage, "Seedling")
        let seedling = JournalGrowthSummary(plant: makePlant())
        XCTAssertEqual(seedling.waterProgress, "250 / 400")
        XCTAssertEqual(seedling.exactWaterProgress, "250 of 400 water")
        XCTAssertEqual(seedling.fraction, 0.5)
        let historical = JournalGrowthSummary(plant: makePlant(growth: "240000000", start: "40000000", next: "840000000"))
        XCTAssertEqual(historical.waterProgress, "240 / 840")
        XCTAssertEqual(historical.fraction, 0.25)
        let fractional = JournalGrowthSummary(plant: makePlant(growth: "399999999"))
        XCTAssertEqual(fractional.exactWaterProgress, "\(ExactAmount.water("399999999")) of 400 water")
    }
    func testFullProfileHandlesMaturityAndUnavailableWaterWithoutInventingAThreshold() {
        let adult = JournalGrowthSummary(plant: makePlant(stage: .adult, growth: "1000000000", start: "1000000000", next: nil))
        XCTAssertEqual(adult.waterProgress, "\(JournalAmount.water("1000000000")) / \(JournalAmount.water("1000000000"))")
        XCTAssertEqual(adult.fraction, 1)
        XCTAssertNil(adult.nextStage)
        var missing = makePlant(); missing.growthProgress = nil
        for plant in [missing, makePlant(growth: "invalid"), makePlant(growth: "1000000001"), makePlant(next: nil)] {
            let display = JournalGrowthSummary(plant: plant)
            XCTAssertNil(display.waterProgress)
            XCTAssertNil(display.exactWaterProgress)
        }
    }
    func testOwnedMetadataKeepsPinnedValuesWhenCurrentCatalogueHasDifferentRules() throws {
        let pinned = APIProfileReference(id: "old", version: 1)
        var plant = makePlant()
        plant.pinnedProfiles = APIPinnedProfiles(growth: pinned, behaviour: pinned, attraction: pinned)
        var catalogue = APICatalogue(catalogVersion: "current", isFixture: true, coordinateUnit: "garden_unit",
            gardenUnitMetres: 1, coordinateDecimalPlaces: 3, rotationDecimalPlaces: 2, species: [],
            profiles: ["behaviour": [APICatalogueProfile(id: "old", version: 2, metricMultipliers: ["steps": 9])],
                       "attraction": [APICatalogueProfile(id: "old", version: 2, gameplayTags: ["herb"])]])
        XCTAssertTrue(JournalOwnedPlantMetadata.multipliers(plant, catalogue: catalogue).isEmpty)
        XCTAssertTrue(JournalOwnedPlantMetadata.tags(plant, catalogue: catalogue).isEmpty)
        plant.metricMultipliers = ["steps": 1, "workout_minutes.*": Decimal(string: "0.25")!]
        plant.gameplayTags = ["tree", "woodland"]
        XCTAssertEqual(JournalOwnedPlantMetadata.multipliers(plant, catalogue: catalogue), plant.metricMultipliers)
        XCTAssertEqual(JournalOwnedPlantMetadata.tags(plant, catalogue: catalogue), ["tree", "woodland"])
        // Older responses can still resolve an exact matching profile, including in storage.
        plant.metricMultipliers = nil; plant.gameplayTags = nil
        catalogue.profiles = ["behaviour": [APICatalogueProfile(id: "old", version: 1, metricMultipliers: ["steps": 1])],
                              "attraction": [APICatalogueProfile(id: "old", version: 1, gameplayTags: ["tree"])]]
        XCTAssertEqual(JournalOwnedPlantMetadata.multipliers(plant, catalogue: catalogue), ["steps": 1])
        XCTAssertEqual(JournalOwnedPlantMetadata.tags(plant, catalogue: catalogue), ["tree"])
        // A known empty value must not fall back to a different display.
        plant.metricMultipliers = [:]; plant.gameplayTags = []
        XCTAssertTrue(JournalOwnedPlantMetadata.multipliers(plant, catalogue: catalogue).isEmpty)
        XCTAssertTrue(JournalOwnedPlantMetadata.tags(plant, catalogue: catalogue).isEmpty)
    }
    func testTagPresentationKeepsTraitsAndOmitsRepeatedRarity() {
        XCTAssertEqual(JournalPlantTags.visible(["herb", "flowering", "rare", "woodland", "Herb", "", "  "]),
                       ["Herb", "Flowering", "Woodland"])
        XCTAssertEqual(JournalPlantTags.visible(["under_story", "ground-cover"]), ["Under Story", "Ground Cover"])
    }
    @MainActor
    func testProfileSectionsFitNarrowAndAccessibilityWidths() {
        let multipliers: [String: Decimal] = ["steps": 1, "flights_climbed": 10,
            "workout_minutes.*": Decimal(string: "0.25")!, "workout_minutes.running": Decimal(string: "0.375")!]
        var unavailable = makePlant(); unavailable.growthProgress = nil
        for textSize: DynamicTypeSize in [.large, .xxxLarge, .accessibility5] {
            for width: CGFloat in [232, 302] {
                for plant in [makePlant(), unavailable,
                              makePlant(stage: .sprout, growth: "100000", start: "0", next: "45000000"),
                              makePlant(stage: .young, growth: "999999999", start: "400000000", next: "1000000000"),
                              makePlant(stage: .adult, growth: "1000000000", start: "1000000000", next: nil)] {
                    let host = UIHostingController(rootView:
                        VStack {
                            JournalPlantTagList(tags: ["herb", "flowering", "woodland", "understory"])
                            JournalPlantDetailProgress(plant: plant)
                            JournalPlantMultipliers(multipliers: multipliers)
                        }.environment(\.dynamicTypeSize, textSize))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 4000))
                    XCTAssertLessThanOrEqual(size.width, width + 1)
                    XCTAssertTrue(size.height.isFinite)
                    XCTAssertGreaterThan(size.height, 44)
                }
            }
        }
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
    func testLastOpeningReceiptIsCompactAndReflowsAtAccessibilitySizes() throws {
        let assets = try BundleAssetCatalog()
        let receipt = APICollectionReceipt(requestId: UUID(), tokenBalance: "4", economyVersion: 1,
            openingId: UUID(), rarity: "rare", plant: makePlant())
        for width: CGFloat in [232, 320] {
            for textSize: DynamicTypeSize in [.large, .accessibility3] {
                let host = UIHostingController(rootView:
                    CollectionPlantReceiptCard(receipt: receipt, catalogue: nil, assets: assets)
                        .environment(\.dynamicTypeSize, textSize))
                let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                XCTAssertLessThanOrEqual(size.width, width + 1)
                XCTAssertGreaterThanOrEqual(size.height, 84)
                XCTAssertTrue(size.height.isFinite)
                if textSize == .large { XCTAssertLessThanOrEqual(size.height, 144) }
            }
        }
    }
    @MainActor
    func testPurchasePopupFitsNarrowScreensAndAccessibilityTextWithoutShrinkingItsCloseTarget() throws {
        let receipt = APICollectionReceipt(requestId: UUID(), tokenBalance: "4", economyVersion: 1,
            exchangeId: UUID(), quantity: 2)
        let notice = try XCTUnwrap(ShopPurchaseNotice(receipt: receipt))
        for textSize: DynamicTypeSize in [.large, .accessibility3] {
            let host = UIHostingController(rootView:
                ShopPurchasePopup(notice: notice, close: {}).environment(\.dynamicTypeSize, textSize))
            let size = host.sizeThatFits(in: CGSize(width: 232, height: 2000))
            XCTAssertLessThanOrEqual(size.width, 233)
            XCTAssertGreaterThanOrEqual(size.height, 52)
            XCTAssertTrue(size.height.isFinite)
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
        for width: CGFloat in [248, 288, 358] {
            for textSize: DynamicTypeSize in [.large, .xxxLarge, .accessibility3] {
                for balance: String? in [nil, "0", "9223372036854775807"] {
                    let host = UIHostingController(rootView:
                        CollectionWalletSummary(balance: balance, capacity: capacity, showsPlants: true,
                            cached: true, gems: "9223372036854775807")
                            .environment(\.dynamicTypeSize, textSize))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                    XCTAssertLessThanOrEqual(size.width, width + 1)
                    XCTAssertTrue(size.height.isFinite)
                    XCTAssertGreaterThan(size.height, 44)
                }
            }
        }
    }

    func testCatalogSortsByRarityThenNameWithUnknownRaritiesLast() {
        func species(_ id: String, _ name: String, _ rarity: String?) -> APISpecies {
            APISpecies(speciesId: id, displayName: name, clearanceRadius: 1, variants: [], rarity: rarity)
        }
        let items = [species("unknown", "A", nil), species("legendary", "A", "legendary"),
            species("epic", "A", "epic"), species("rare", "A", "rare"),
            species("oak", "Oak", "common"), species("amber", "Amber", "common")]
        XCTAssertEqual(CatalogPresentation.sortedSpecies(items).map(\.speciesId),
                       ["amber", "oak", "rare", "epic", "legendary", "unknown"])
        let ties = [species("b", "Oak", "common"), species("a", "Oak", "common")]
        XCTAssertEqual(CatalogPresentation.sortedSpecies(ties).map(\.speciesId), ["a", "b"])
    }

    func testCatalogVariantsAlwaysPutStandardFirstThenNamesAndStableIDs() {
        func variant(_ id: String, _ name: String) -> APIVariant {
            APIVariant(variantId: id, displayName: name, assetCatalogVersion: "1", stages: [:])
        }
        let variants = [variant("vined", "Vined"), variant("blue-b", "Blue"),
                        variant("standard", "Standard"), variant("blue-a", "Blue"), variant("z-amber", "Amber")]
        let expected = ["standard", "z-amber", "blue-a", "blue-b", "vined"]
        XCTAssertEqual(CatalogPresentation.sortedVariants(variants).map(\.variantId), expected)
        XCTAssertEqual(CatalogPresentation.sortedVariants(Array(variants.reversed())).map(\.variantId), expected)
        XCTAssertEqual(CatalogPresentation.sortedVariants(variants.filter { $0.variantId != "standard" }).map(\.variantId),
                       Array(expected.dropFirst()))
        XCTAssertTrue(CatalogPresentation.sortedVariants([]).isEmpty)
    }

    private func collectionCatalogue() -> APICatalogue {
        let species = [("oak", ["standard", "blue", "vined"]), ("moonwillow", ["standard", "silver"])].map { id, variants in
            APISpecies(speciesId: id, displayName: id, clearanceRadius: 1, variants: variants.map {
                APIVariant(variantId: $0, displayName: $0, assetCatalogVersion: "1", stages: [:])
            })
        }
        return APICatalogue(catalogVersion: "collection-test", isFixture: true, coordinateUnit: "garden_unit",
                            gardenUnitMetres: 1, coordinateDecimalPlaces: 3, rotationDecimalPlaces: 2, species: species)
    }

    func testCollectionCountsUniqueAcquiredSpeciesAndNonStandardVariantsInTheFullCatalog() throws {
        let catalogue = collectionCatalogue()
        let discovery = APICatalogDiscovery(userId: UUID(), catalogVersion: catalogue.catalogVersion, discoveryVersion: 1,
            entries: [.init(speciesId: "oak", variantId: "standard", stages: GrowthStage.allCases),
                      .init(speciesId: "oak", variantId: "blue", stages: [.sprout, .seedling]),
                      .init(speciesId: "moonwillow", variantId: "silver", stages: [.sprout]),
                      .init(speciesId: "retired", variantId: "blue", stages: GrowthStage.allCases),
                      .init(speciesId: "oak", variantId: "retired", stages: [.sprout])])
        let counts = try XCTUnwrap(CatalogCollectionCounts(catalogue: catalogue, discovery: discovery))
        XCTAssertEqual(counts.collectedPlants, 2)
        XCTAssertEqual(counts.totalPlants, 2)
        XCTAssertEqual(counts.collectedVariants, 2)
        XCTAssertEqual(counts.totalVariants, 3)
        // A coloured variant acquires its species without granting Standard or sibling variants.
        let variantOnly = APICatalogDiscovery(userId: discovery.userId, catalogVersion: catalogue.catalogVersion,
            discoveryVersion: 1, entries: [.init(speciesId: "oak", variantId: "blue", stages: [.sprout])])
        let partial = try XCTUnwrap(CatalogCollectionCounts(catalogue: catalogue, discovery: variantOnly))
        XCTAssertEqual(partial.collectedPlants, 1)
        XCTAssertEqual(partial.totalPlants, 2)
        XCTAssertEqual(partial.collectedVariants, 1)
        XCTAssertEqual(partial.totalVariants, 3)
    }

    func testCollectionDistinguishesConfirmedZeroFromMissingOrMismatchedData() throws {
        let catalogue = collectionCatalogue()
        let empty = APICatalogDiscovery(userId: UUID(), catalogVersion: catalogue.catalogVersion, discoveryVersion: 0, entries: [])
        let zero = try XCTUnwrap(CatalogCollectionCounts(catalogue: catalogue, discovery: empty))
        XCTAssertEqual(zero.collectedPlants, 0)
        XCTAssertEqual(zero.collectedVariants, 0)
        XCTAssertEqual(zero.totalPlants, 2)
        XCTAssertEqual(zero.totalVariants, 3)
        XCTAssertNil(CatalogCollectionCounts(catalogue: nil, discovery: empty))
        XCTAssertNil(CatalogCollectionCounts(catalogue: catalogue, discovery: nil))
        let old = APICatalogDiscovery(userId: empty.userId, catalogVersion: "old", discoveryVersion: 0, entries: [])
        XCTAssertNil(CatalogCollectionCounts(catalogue: catalogue, discovery: old))
        let standardOnly = APICatalogue(catalogVersion: catalogue.catalogVersion, isFixture: true, coordinateUnit: "garden_unit",
            gardenUnitMetres: 1, coordinateDecimalPlaces: 3, rotationDecimalPlaces: 2,
            species: [APISpecies(speciesId: "oak", displayName: "Oak", clearanceRadius: 1,
                variants: [APIVariant(variantId: "standard", displayName: "Standard", assetCatalogVersion: "1", stages: [:])])])
        XCTAssertEqual(CatalogCollectionCounts(catalogue: standardOnly, discovery: empty)?.totalVariants, 0)
    }

    func testSpeciesPortraitUsesOnlyAnAcquiredVariantAndPrefersStandard() {
        let variants = ["standard", "vined", "blue"].map {
            APIVariant(variantId: $0, displayName: $0, assetCatalogVersion: "1.0.0", stages: [:])
        }
        let species = APISpecies(speciesId: "oak", displayName: "Oak", clearanceRadius: 1, variants: variants)
        var keys = Set<CatalogDiscoveryKey>()
        XCTAssertNil(CatalogPresentation.portraitVariant(species, discovered: keys))
        keys.insert(.init(species: "oak", variant: "vined", stage: .sprout))
        XCTAssertEqual(CatalogPresentation.portraitVariant(species, discovered: keys)?.variantId, "vined")
        keys.insert(.init(species: "oak", variant: "blue", stage: .sprout))
        XCTAssertEqual(CatalogPresentation.portraitVariant(species, discovered: keys)?.variantId, "blue")
        keys.insert(.init(species: "oak", variant: "standard", stage: .sprout))
        XCTAssertEqual(CatalogPresentation.portraitVariant(species, discovered: keys)?.variantId, "standard")
    }

    @MainActor
    func testLockedCatalogArtworkNeverResolvesSpeciesImage() {
        let assets = CatalogImageProbe()
        let plant = GardenPlant(id: UUID(), speciesId: "oak", variantId: "standard", assetVersion: "1.0.0",
                                growthStage: .adult, x: 0, y: 0, rotationDegrees: 0)
        let host = UIHostingController(rootView: CatalogPlantArtwork(plant: plant, catalog: assets, revealed: false)
            .frame(width: 100, height: 100))
        _ = host.sizeThatFits(in: CGSize(width: 100, height: 100))
        host.view.layoutIfNeeded()
        XCTAssertEqual(assets.resolutions, 0)
        let revealed = UIHostingController(rootView: CatalogPlantArtwork(plant: plant, catalog: assets, revealed: true)
            .frame(width: 100, height: 100))
        _ = revealed.sizeThatFits(in: CGSize(width: 100, height: 100))
        revealed.view.layoutIfNeeded()
        XCTAssertGreaterThan(assets.resolutions, 0, "The rendered positive control must attempt image resolution")
    }
}

private final class CatalogImageProbe: AssetCatalogProviding {
    let species: [SpeciesManifest] = []
    var resolutions = 0
    func resolve(speciesId: String, version: String, stage: GrowthStage, variant: String) throws -> ResolvedPlantAsset {
        resolutions += 1
        throw ForestError.missingResource("test image")
    }
}
