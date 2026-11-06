import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import MovementForest

@MainActor
private struct PresentationTestService: AccountSummaryServing {
    let serverID = "https://progression-presentation-test.invalid"
    let value: APIAccountSummary
    func accountSummary() async throws -> APIAccountSummary { value }
}

@MainActor
private final class PresentationTestCache: AccountSummaryPersisting {
    func load(server: String, user: UUID) throws -> AccountSummaryCache? { nil }
    func save(_ value: AccountSummaryCache, server: String, user: UUID) throws { }
}

@MainActor
final class AccountPresentationTests: XCTestCase {
    private func fixture(_ key: String = "grown") throws -> APIAccountSummary {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "account-summary-contract", withExtension: "json", subdirectory: "Fixtures"))
        let values = try ActivityWire.decoder().decode([String: APIAccountSummary].self, from: Data(contentsOf: url))
        return try XCTUnwrap(values[key])
    }

    func testFullIntegerFormattingPreservesLargeBalances() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(AccountDisplay.amount("9223372036854775807", locale: locale), "9,223,372,036,854,775,807")
        XCTAssertEqual(AccountDisplay.amount("0", locale: locale), "0")
        for value in [nil, "", "-1", "01", "2.5", "9223372036854775808"] as [String?] {
            XCTAssertEqual(AccountDisplay.amount(value, locale: locale), "Unavailable")
        }
    }

    func testBothProgressTracksUseTheActualBackendRemainders() throws {
        let display = AccountProgressDisplay(progression: try fixture().progression)
        XCTAssertEqual(display.level, "Level 5")
        XCTAssertEqual(display.nextLevel, "Level 6")
        XCTAssertEqual(display.xp, "22 / 150 XP")
        XCTAssertEqual(display.xpFraction, 22.0 / 150, accuracy: 0.000001)
        XCTAssertEqual(display.gemFraction, 0.725, accuracy: 0.000001)
    }

    func testNewAccountStartsWithEmptyTracksAndRealZeroGems() throws {
        let value = try fixture("fresh")
        let display = AccountProgressDisplay(progression: value.progression)
        XCTAssertEqual(display.level, "Level 1")
        XCTAssertEqual(display.xp, "0 / 50 XP")
        XCTAssertEqual(display.xpFraction, 0)
        XCTAssertEqual(display.gemFraction, 0)
        XCTAssertEqual(AccountDisplay.gemBalance(value.wallet), "0")
        XCTAssertEqual(AccountDisplay.gemBalance(nil), "Unavailable")
    }

    func testPreparingWalletDoesNotPresentAnAuthoritativeZero() throws {
        let source = try fixture().wallet
        let pending = APIAccountWallet(economyVersion: source.economyVersion, tokenBalance: source.tokenBalance,
            gemBalance: "0", lifetimeGemsEarned: "0", initialized: false, hostedActive: source.hostedActive,
            hostedOffline: source.hostedOffline, hostedTotal: source.hostedTotal)
        XCTAssertEqual(AccountDisplay.gemBalance(pending), "Preparing")
    }

    func testGemAndLevelBoundariesDisplayTheNewRemainders() throws {
        let original = try fixture().progression
        let p = APIAccountProgression(rulesVersion: original.rulesVersion, version: 1,
            lifetimeRecordedSteps: "10000", stepXp: "100", totalXp: "100", level: 2,
            xpIntoLevel: "50", xpForNextLevel: "75", stepsIntoNextGem: 0, stepsPerGem: 10000,
            stepsToNextGem: 10000, plantsGrownToAdulthood: "0", lastSyncAt: original.lastSyncAt)
        let display = AccountProgressDisplay(progression: p)
        XCTAssertEqual(display.gemFraction, 0)
        XCTAssertEqual(display.xpFraction, 2.0 / 3, accuracy: 0.000001)
        let boundary = APIAccountProgression(rulesVersion: original.rulesVersion, version: 2,
            lifetimeRecordedSteps: "12500", stepXp: "125", totalXp: "125", level: 3,
            xpIntoLevel: "0", xpForNextLevel: "100", stepsIntoNextGem: 2500, stepsPerGem: 10000,
            stepsToNextGem: 7500, plantsGrownToAdulthood: "0", lastSyncAt: original.lastSyncAt)
        XCTAssertEqual(AccountProgressDisplay(progression: boundary).xpFraction, 0)
        XCTAssertEqual(AccountProgressDisplay(progression: boundary).gemFraction, 0.25)
    }

    func testProgressionArtworkIsBundledAtTheRuntimeBudget() throws {
        for key in ["gems", "xp"] {
            let path = try XCTUnwrap(QuantityArtwork.path(key))
            XCTAssertEqual(path, "png-128/\(key).png")
            let image = try XCTUnwrap(QuantityArtwork.images[key])
            XCTAssertEqual(image.cgImage?.width, 128)
            XCTAssertEqual(image.cgImage?.height, 128)
        }
        XCTAssertEqual(QuantityArtwork.symbol("gems"), "diamond.fill")
        XCTAssertEqual(QuantityArtwork.symbol("xp"), "star.fill")
    }

    func testHomeHeaderKeepsTheFullSceneAndClipsItsExclusionFramesAtLargeText() async throws {
        let value = try fixture()
        let store = AccountSummaryStore(userID: value.profile.userId, service: PresentationTestService(value: value),
            cache: PresentationTestCache())
        await store.refresh()
        var frames: [CGRect] = []
        var sceneSize = CGSize.zero
        let content = GardenViewportLayout(compact: false) {
            GeometryReader { geometry in
                Color.clear.onAppear { sceneSize = geometry.size }
            }
        } status: {
            HomeAccountHeader(store: store, openProfile: { _ in })
        } controls: { EmptyView() }
        .environment(\.dynamicTypeSize, .accessibility3)
        .frame(width: 320, height: 500)
        .onPreferenceChange(GardenOverlayFrames.self) { frames = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if !frames.isEmpty && sceneSize != .zero { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sceneSize.width, 320, accuracy: 1)
        XCTAssertEqual(sceneSize.height, 500, accuracy: 1)
        XCTAssertFalse(frames.isEmpty)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, 275.5)
        }
    }

    func testCompactHomeHeaderUsesAtMost132PointsOnSmallPortrait() async throws {
        let value = try fixture()
        let store = AccountSummaryStore(userID: value.profile.userId, service: PresentationTestService(value: value),
            cache: PresentationTestCache())
        await store.refresh()
        let header = UIHostingController(rootView:
            HomeAccountHeader(store: store, attraction: "141.3", openProfile: { _ in })
                .environment(\.dynamicTypeSize, .large))
        let size = header.sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertGreaterThanOrEqual(size.height, 88)
        XCTAssertLessThanOrEqual(size.height, 132.5, "Normal Home must use three tight 44-point rows")
        let metrics = UIHostingController(rootView:
            GardenSummaryHeader(tokens: "9,142", attraction: "141.3", stored: "106/1500", gems: "7",
                information: {}, collect: {}).environment(\.dynamicTypeSize, .large))
        XCTAssertLessThanOrEqual(metrics.sizeThatFits(in: CGSize(width: 320, height: 1000)).height, 88.5)
    }
}
