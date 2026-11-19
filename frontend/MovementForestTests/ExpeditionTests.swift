import XCTest
import SwiftUI
@testable import MovementForest

@MainActor
final class ExpeditionTests: XCTestCase {
    struct Contract: Decodable {
        let synthetic: Bool
        let initial: ExpeditionRun
        let earned: ExpeditionRun
        let restored: ExpeditionRun
        let receipts: [APICollectionReceipt]
    }
    func testHTTPContractCompletionAndCollectionAreIndependent() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "expeditions-contract", withExtension: "json", subdirectory: "Fixtures"))
        let contract = try ActivityWire.decoder().decode(Contract.self, from: Data(contentsOf: url))
        _ = try contract.initial.validated(); _ = try contract.earned.validated(); _ = try contract.restored.validated()
        XCTAssertEqual(contract.initial.timezone, "UTC")
        XCTAssertEqual(contract.earned.completedCount, 9)
        XCTAssertTrue(contract.earned.quests.allSatisfy { !$0.claimed })
        XCTAssertTrue(contract.restored.quests.allSatisfy { $0.claimed })
        XCTAssertEqual(contract.earned.rewards.count, 11)
        XCTAssertEqual(contract.receipts.compactMap(\.ownedItemIds).flatMap { $0 }.count, 3)
        let piece = try XCTUnwrap(contract.earned.quests.first?.entitlement)
        let local = contract.earned.confirmingClaims([piece.id])
        XCTAssertTrue(local.quests.first?.claimed == true)
        XCTAssertEqual(local.quests.filter(\.claimed).count, 1)
        XCTAssertEqual(local.completedCount, 9)
    }
    func testPuzzleGeometryPartitionsBoardAndMatchesNeighbours() {
        let board = CGRect(x: 0, y: 0, width: 360, height: 360)
        let paths = (0..<9).map { ExpeditionPieceShape(index: $0).path(in: board) }
        // Sample away from grid/curve boundaries: every pixel belongs to one piece.
        for x in stride(from: CGFloat(0.37), to: 360, by: 2.71) {
            for y in stride(from: CGFloat(0.53), to: 360, by: 3.19) {
                XCTAssertEqual(paths.filter { $0.contains(CGPoint(x: x, y: y)) }.count, 1)
            }
        }
    }
    func testQuantityFirstRewardsRetainAccessibleNames() {
        let tokens = ExpeditionReward(tokens: 250)
        XCTAssertEqual(tokens.quantity, "250")
        XCTAssertEqual(tokens.accessibilityName, "250 tokens")
        XCTAssertEqual(ExpeditionReward(itemId: "comet-basin").accessibilityName, "1 Comet-Catcher's Basin")
    }
    func testPendingClaimPinsRunAndEntitlementAcrossRollover() throws {
        let id = UUID(), run = UUID(), entitlement = UUID()
        let operation = PendingCollectionOperation(id: id, kind: .expeditionClaim, target: nil,
            body: try ActivityWire.encoder().encode(CollectionOpenBody(requestId: id)), runID: run, entitlementID: entitlement)
        try operation.validate()
        let decoded = try ActivityWire.decoder().decode(PendingCollectionOperation.self, from: ActivityWire.encoder().encode(operation))
        XCTAssertEqual(decoded.runID, run); XCTAssertEqual(decoded.entitlementID, entitlement)
    }
}
