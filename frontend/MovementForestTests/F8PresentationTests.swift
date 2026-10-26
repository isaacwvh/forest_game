import XCTest
import UIKit
@testable import MovementForest

@MainActor
final class F8PresentationTests: XCTestCase {
    func testVisitorTargetsKeepVisibleEdgesAndExcludeHeaderAndOffscreenArtwork() throws {
        let viewport = CGRect(x: 0, y: 0, width: 320, height: 400)
        let id = UUID()
        let edge = try XCTUnwrap(VisitorHitTarget(id: id, artwork: CGRect(x: 140, y: -8, width: 30, height: 30), viewport: viewport))
        XCTAssertEqual(VisitorHitTarget.pick(at: CGPoint(x: 155, y: 2), from: [edge]), id)
        XCTAssertNil(VisitorHitTarget.pick(at: CGPoint(x: 155, y: -1), from: [edge]))
        XCTAssertNil(VisitorHitTarget(id: id, artwork: CGRect(x: 140, y: -50, width: 30, height: 30), viewport: viewport))
        let centre = try XCTUnwrap(VisitorHitTarget(id: id, artwork: CGRect(x: 140, y: 120, width: 20, height: 20), viewport: viewport))
        XCTAssertEqual(centre.touch.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(centre.touch.midX, centre.artwork.midX)
        XCTAssertEqual(centre.touch.midY, centre.artwork.midY)
    }

    func testVisitorSelectionPrefersVisibleArtworkOverAnotherPaddedTarget() throws {
        let viewport = CGRect(x: 0, y: 0, width: 320, height: 400)
        let first = try XCTUnwrap(VisitorHitTarget(id: UUID(), artwork: CGRect(x: 100, y: 100, width: 20, height: 20), viewport: viewport))
        let second = try XCTUnwrap(VisitorHitTarget(id: UUID(), artwork: CGRect(x: 125, y: 100, width: 20, height: 20), viewport: viewport))
        let point = CGPoint(x: 126, y: 110)
        XCTAssertTrue(first.touch.contains(point))
        XCTAssertEqual(VisitorHitTarget.pick(at: point, from: [first, second]), second.id)
        XCTAssertEqual(VisitorHitTarget.pick(at: point, from: [second, first]), second.id)
    }

    func testQuantityArtworkResolvesRuntimeExportsAndKeepsWorkoutFallbackDistinct() throws {
        for key in QuantityArtwork.keys {
            let path = try XCTUnwrap(QuantityArtwork.path(key))
            let image = try XCTUnwrap(PresentationAssets.image(path, maximumPixels: 128))
            let pixels = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(pixels.width, 128)
            XCTAssertEqual(pixels.height, 128)
        }
        XCTAssertNil(QuantityArtwork.path("workout_minutes.*"))
        XCTAssertNil(QuantityArtwork.path("../tokens"))
        XCTAssertEqual(QuantityArtwork.workoutKey(37), "workout_minutes.running")
        XCTAssertEqual(QuantityArtwork.workoutKey(20), "workout_minutes.strength_training")
        XCTAssertEqual(QuantityArtwork.workoutKey(50), "workout_minutes.strength_training")
        XCTAssertEqual(QuantityArtwork.workoutKey(10_000), "workout_minutes.unknown")
        XCTAssertNotEqual(ActivityMetricLabel.title("workout_minutes.*"), ActivityMetricLabel.title("workout_minutes.unknown"))
    }

    func testEntryGateSuppressesRoutineRefreshesAndRearmsAfterBackground() {
        var gate = AppEntryGate()
        let account = UUID()
        XCTAssertTrue(gate.enter(account: account))
        for _ in 0..<20 { XCTAssertFalse(gate.enter(account: account)) }
        gate.background(at: 100)
        gate.foreground(at: 130)
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
