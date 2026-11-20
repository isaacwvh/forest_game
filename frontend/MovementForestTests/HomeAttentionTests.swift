import XCTest
@testable import MovementForest

final class HomeAttentionTests: XCTestCase {
    func testConfirmedAttentionAndStaleSnapshotRecovery() throws {
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Fixtures")
        XCTAssertEqual(try HomeAttentionChecks.run(fixtures: fixtures), 20)
    }
}
