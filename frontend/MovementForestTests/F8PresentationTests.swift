import XCTest
import UIKit
@testable import MovementForest

@MainActor
final class F8PresentationTests: XCTestCase {
    func testEntryGateSuppressesRoutineRefreshesAndRearmsAfterBackground() {
        var gate = AppEntryGate()
        let account = UUID()
        XCTAssertTrue(gate.enter(account: account))
        for _ in 0..<20 { XCTAssertFalse(gate.enter(account: account)) }
        gate.background()
        XCTAssertTrue(gate.enter(account: account))
        XCTAssertFalse(gate.enter(account: account))
        XCTAssertTrue(gate.enter(account: account, server: "https://second-environment.invalid"))
        XCTAssertTrue(gate.enter(account: UUID()))
        gate.signOut()
        XCTAssertTrue(gate.enter(account: account))
    }

    func testRecapMergesConfirmedCreditsWithoutCountingReceiptReplayTwice() throws {
        let id = UUID(), other = UUID()
        func recap(_ before: String, _ after: String, _ award: String, _ bonus: String,
                   _ beforeStage: GrowthStage, _ afterStage: GrowthStage) -> APIRewardRecap {
            APIRewardRecap(recapId: UUID(), createdAt: Date(), payload: .init(kind: "activity_growth", creditIds: [],
                plants: [.init(plantId: id, beforeGrowthMicroUnits: before, afterGrowthMicroUnits: after,
                               awardedGrowthMicroUnits: award, beforeStage: beforeStage, afterStage: afterStage,
                               skillBonusGrowthMicroUnits: bonus)], activityDays: [], resourceDeltas: [:]))
        }
        let first = recap("0", "1040000", "1040000", "40000", .sprout, .seedling)
        let second = recap("1040000", "2600000", "1560000", "60000", .seedling, .young)
        let untouched = APIOwnedPlant(plantId: other, speciesId: "oak", variantId: "standard", growthMicroUnits: "0",
            growthStage: .sprout, modelKey: "", thumbnailKey: "", placement: nil)
        let rows = ActivityRecapRow.make(recaps: [second, first, first], plants: [untouched])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, id)
        XCTAssertEqual(rows.first?.water, "2600000")
        XCTAssertEqual(rows.first?.skillWater, "100000")
        XCTAssertEqual(rows.first?.beforeStage, .sprout)
        XCTAssertEqual(rows.first?.afterStage, .young)
        XCTAssertEqual(rows.last?.plant?.id, other)
        XCTAssertEqual(rows.last?.water, "0")
    }

    func testBundledPresentationAssetsResolveAndDecodeWithinDisplayBudget() throws {
        for part in ["sealed", "opened", "top-strip"] {
            let path = try XCTUnwrap(PresentationAssets.packPath(packID: "woodland", part: part))
            let image = try XCTUnwrap(PresentationAssets.image(path, maximumPixels: 900))
            let pixels = try XCTUnwrap(image.cgImage)
            XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 900)
        }
        XCTAssertNil(PresentationAssets.packPath(packID: "moonwillow", part: "sealed"))
        XCTAssertNil(PresentationAssets.url("../Configuration/Auth.xcconfig"))
        let (manifest, model) = try VisitorAssetManifest.load()
        XCTAssertEqual(manifest.visitorId, "butterfly")
        XCTAssertEqual(model.lastPathComponent, "butterfly-standard.usdz")
    }

    func testWorldFlightUsesGardenDimensionsAndReducedMotionIsStable() {
        let small = VisitorWorldPose(elapsed: 10, remaining: 20, lane: 4, width: 10, depth: 10, height: 3, reduceMotion: false)
        let large = VisitorWorldPose(elapsed: 10, remaining: 20, lane: 4, width: 20, depth: 20, height: 3, reduceMotion: false)
        XCTAssertEqual(large.position.x, small.position.x * 2, accuracy: 0.0001)
        XCTAssertEqual(large.position.z, small.position.z * 2, accuracy: 0.0001)
        let poses = (1...12).map { lane in
            VisitorWorldPose(elapsed: 0, remaining: 20, lane: lane, width: 10, depth: 10, height: 3, reduceMotion: true)
        }
        XCTAssertEqual(Set(poses.map { "\($0.position.x),\($0.position.z)" }).count, 12)
        let later = VisitorWorldPose(elapsed: 15, remaining: 1, lane: 4, width: 10, depth: 10, height: 3, reduceMotion: true)
        XCTAssertEqual(poses[3].position, later.position)
    }
}
