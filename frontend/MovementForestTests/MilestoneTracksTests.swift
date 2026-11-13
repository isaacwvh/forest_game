import Foundation
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
}
