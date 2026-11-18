import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import MovementForest

private struct MilestoneContract: Decodable {
    let synthetic: Bool
    let fresh: APICollectionSummary
    let earned: APICollectionSummary
    let receipt: APICollectionReceipt
    let packReceipt: APICollectionReceipt
    let account: APIAccountSummary
}

@MainActor
final class MilestoneTracksTests: XCTestCase {
    private func fixture() throws -> MilestoneContract {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "milestones-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(MilestoneContract.self, from: Data(contentsOf: url))
    }
    func testRealHTTPTrackContractAndCatalogueEndpoints() throws {
        let contract = try fixture()
        XCTAssertTrue(contract.synthetic)
        let rows = try XCTUnwrap(contract.fresh.milestones)
        XCTAssertEqual(rows.count, 62)
        XCTAssertEqual(Set(rows.compactMap(\.track)), ["steps", "butterfly", "growth", "special"])
        XCTAssertEqual(rows.first { $0.id == "discovery_epic_7" }?.threshold, 7)
        XCTAssertEqual(rows.first { $0.id == "discovery_legendary_3" }?.threshold, 3)
        XCTAssertNil(rows.first { $0.id == "discovery_epic_10" })
        XCTAssertEqual(MilestoneTrack.allCases.count, 5)
        XCTAssertTrue(MilestoneTrack.steps.timeline)
        XCTAssertFalse(MilestoneTrack.growth.timeline)
    }
    func testDirectPackAndMixedCurrencyReceiptsDecodeWithoutOpening() throws {
        let contract = try fixture()
        XCTAssertEqual(contract.receipt.tokensEarned, "1200")
        XCTAssertEqual(contract.receipt.gemsEarned, "2")
        XCTAssertEqual(contract.packReceipt.packs?.count, 1)
        XCTAssertEqual(contract.packReceipt.packs?.first?.version, 20)
        XCTAssertNil(contract.packReceipt.openingId)
        XCTAssertNil(contract.packReceipt.plant)
        _ = try contract.account.validated(user: contract.account.profile.userId)
        XCTAssertEqual(contract.account.wallet.stepGemsEarned, "20")
        XCTAssertEqual(contract.account.wallet.bonusGemsEarned, "2")
    }
    func testProgressUsesItsOwnThresholdAndMalformedDataStaysUnavailable() throws {
        var row = try XCTUnwrap(fixture().earned.milestones?.first { $0.id == "steps_500000" })
        XCTAssertEqual(row.progressFraction, 0.4, accuracy: 0.000001)
        row.progress = "0"
        XCTAssertEqual(row.progressFraction, 0)
        row.progress = "1/2"
        XCTAssertEqual(row.progressValue, 0.5)
        for invalid in ["", "1/0", "NaN", "-1", "1/2/3"] {
            row.progress = invalid
            XCTAssertNil(row.progressValue)
        }
    }
    func testTrackAndScrollSelectionSurvivePendingClaimJournalEncoding() throws {
        let request = UUID()
        let body = try ActivityWire.encoder().encode(CollectionOpenBody(requestId: request))
        let state = CollectionJournalState(pending: PendingCollectionOperation(id: request,
            kind: .milestone, target: nil, body: body, milestoneID: "steps_1000"),
            milestoneTrack: "growth", milestoneScroll: ["growth": "discovery_epic_7"])
        let decoded = try ActivityWire.decoder().decode(CollectionJournalState.self,
            from: ActivityWire.encoder().encode(state))
        try decoded.pending?.validate()
        XCTAssertEqual(decoded.milestoneTrack, "growth")
        XCTAssertEqual(decoded.milestoneScroll?["growth"], "discovery_epic_7")
        XCTAssertEqual(decoded.pending?.id, request)
    }

    func testQuestDescriptionsAndRewardAccessibilityKeepTheActualRequirementsAndBundle() {
        let row = APIIntroMilestone(milestoneId: "example", title: "Quest name",
            description: "Grow five mature plants", rewardTokens: "1200", eligible: false, claimed: false,
            rewardGems: "2", rewardPacks: [APIMilestonePackReward(packId: "select-woodland", version: 20,
                quantity: 1, displayName: "Enchanted Woodland")])
        XCTAssertEqual(MilestoneQuestPresentation.description(row), "Grow five mature plants")
        XCTAssertEqual(MilestoneQuestPresentation.rewards(row), "1200 tokens, 2 gems, 1 Enchanted Woodland pack")
    }

    func testEveryQuestHasProgressPresentationWithoutInventingCompletionOrMissingProgress() throws {
        let rows = try XCTUnwrap(fixture().earned.milestones)
        XCTAssertNotNil(MilestoneQuestPresentation.progress(try XCTUnwrap(rows.first { $0.metric == "opening" })))
        var future = try XCTUnwrap(rows.first { $0.id == "steps_500000" })
        let progress = try XCTUnwrap(MilestoneQuestPresentation.progress(future))
        XCTAssertEqual(progress.current, Int64(200000).formatted())
        XCTAssertEqual(progress.target, Int64(500000).formatted())
        XCTAssertEqual(future.progressFraction, 0.4)
        for missing in [nil, "NaN", "1/0"] as [String?] {
            future.progress = missing
            XCTAssertNil(MilestoneQuestPresentation.progress(future))
        }
        let claimed = APIIntroMilestone(milestoneId: "claimed", title: "Daily steps", description: "Daily steps",
            rewardTokens: "300", eligible: false, claimed: true, metric: "daily_steps", threshold: 10000, progress: "20")
        XCTAssertEqual(MilestoneQuestPresentation.progress(claimed)?.current, Int64(20).formatted())
        XCTAssertEqual(claimed.progressFraction, 0.002)
    }

    func testQuestRowsAndRewardStatesKeepUniformFramesAtPhoneAndAccessibilityWidths() throws {
        let rows = try XCTUnwrap(fixture().earned.milestones)
        let longest = try XCTUnwrap(rows.max { $0.description.count < $1.description.count })
        let shortest = try XCTUnwrap(rows.min { $0.description.count < $1.description.count })
        for width: CGFloat in [288, 343, 361, 398] {
            for category: UIContentSizeCategory in [.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
                let traits = UITraitCollection(preferredContentSizeCategory: category)
                let layout = MilestoneQuestLayout(width: width, rows: rows,
                    questFontSize: UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 14, compatibleWith: traits),
                    progressFontSize: UIFontMetrics(forTextStyle: .caption2).scaledValue(for: 10.5, compatibleWith: traits),
                    rewardFontSize: UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 12, compatibleWith: traits),
                    accessibility: category.isAccessibilityCategory)
                XCTAssertLessThanOrEqual(layout.rewardWidth, width - 20)
                XCTAssertGreaterThanOrEqual(layout.rewardWidth, 44)
                XCTAssertGreaterThanOrEqual(layout.rewardHeight, 44)
                if category.isAccessibilityCategory { XCTAssertTrue(layout.stacked) }
                if width == 361 && category == .large {
                    XCTAssertEqual(layout.rowHeight, 88, accuracy: 1)
                    XCTAssertEqual(layout.rewardWidth, 80, accuracy: 1)
                    XCTAssertEqual(layout.rewardHeight, 72, accuracy: 1)
                }
                for row in [shortest, longest] {
                    let states: [(MilestoneRewardBox<Text>.Appearance, String)] = [
                        (.ready, "300"), (.claimed, "Claimed"), (.locked, "Pending"),
                        (.locked, "Pack storage full"), (.locked, "Previously fulfilled"),
                        (.locked, "Included in 10 km reward"), (.locked, "Unavailable")]
                    for (appearance, status) in states {
                        let box = MilestoneRewardBox(layout: layout, appearance: appearance) { Text(status) }
                        let rewardSize = UIHostingController(rootView: box)
                            .sizeThatFits(in: CGSize(width: width, height: 4000))
                        XCTAssertEqual(rewardSize.width, layout.rewardWidth, accuracy: 1)
                        XCTAssertEqual(rewardSize.height, layout.rewardHeight, accuracy: 1)
                        let host = UIHostingController(rootView:
                            MilestoneQuestRow(row: row, track: .growth, layout: layout) { box })
                        let size = host.sizeThatFits(in: CGSize(width: width, height: 4000))
                        XCTAssertEqual(size.width, width, accuracy: 1)
                        XCTAssertEqual(size.height, layout.rowHeight, accuracy: 1)
                    }
                }
            }
        }
    }

    func testThreeRewardTypesAndLongProgressReserveSpaceForEveryRow() {
        let row = APIIntroMilestone(milestoneId: "large", title: "Long requirement",
            description: "First mature plant grown through activity", rewardTokens: "1200", eligible: false,
            claimed: false, threshold: Int64.max, progress: "9223372036854774784", rewardGems: "2",
            rewardPacks: [APIMilestonePackReward(packId: "woodland", version: 20, quantity: 1, displayName: "Standard Woodland")])
        let layout = MilestoneQuestLayout(width: 288, rows: [row])
        XCTAssertTrue(layout.twoLineProgress)
        XCTAssertGreaterThanOrEqual(layout.barHeight, 30)
        XCTAssertGreaterThanOrEqual(layout.rewardHeight, 3 * layout.rewardIconSize + 24)
        let size = UIHostingController(rootView: MilestoneQuestProgress(row: row, layout: layout))
            .sizeThatFits(in: CGSize(width: layout.descriptionWidth, height: 2000))
        XCTAssertLessThanOrEqual(size.width, layout.descriptionWidth + 1)
        XCTAssertEqual(size.height, layout.barHeight, accuracy: 1)
    }
}
