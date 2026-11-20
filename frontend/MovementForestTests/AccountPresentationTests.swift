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

    func testProfileIllustrationsResolveFromExistingBundleWithBoundedDecoding() throws {
        for illustration in ProfileIllustration.allCases {
            XCTAssertNotNil(PresentationAssets.url(illustration.rawValue), "Missing profile artwork: \(illustration)")
            let image = try XCTUnwrap(ProfileIllustration.images[illustration])
            let pixels = try XCTUnwrap(image.cgImage)
            let maximum = illustration == .portrait ? 256 : 128
            XCTAssertGreaterThan(pixels.width, 0)
            XCTAssertGreaterThan(pixels.height, 0)
            XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), maximum)
        }
    }

    func testProfileIdentityReflowsLongNamesAtNarrowAndAccessibilityWidths() throws {
        let source = try fixture()
        let identity = APIAccountIdentity(userId: source.profile.userId,
            username: "a_very_long_forest_keeper_username", displayName: "A very long forest keeper display name",
            gameTimezone: source.profile.gameTimezone, createdAt: source.profile.createdAt)
        let summary = APIAccountSummary(serverTime: source.serverTime, profile: identity,
            progression: source.progression, wallet: source.wallet)
        for width in [280.0, 350.0] {
            let regular = UIHostingController(rootView: ProfileIdentityHeader(summary: summary)
                .environment(\.dynamicTypeSize, .large))
            let accessible = UIHostingController(rootView: ProfileIdentityHeader(summary: summary)
                .environment(\.dynamicTypeSize, .accessibility5))
            let proposal = CGSize(width: width, height: 3000)
            let regularSize = regular.sizeThatFits(in: proposal)
            let accessibleSize = accessible.sizeThatFits(in: proposal)
            XCTAssertLessThanOrEqual(regularSize.width, width + 0.5)
            XCTAssertLessThanOrEqual(accessibleSize.width, width + 0.5)
            XCTAssertGreaterThan(accessibleSize.height, regularSize.height,
                "Long names and progress must grow vertically with Dynamic Type")
        }
    }

    func testProfileWalletAndRecordsStackLongValuesInsteadOfTruncating() throws {
        let source = try fixture()
        var large = source
        let wallet = source.wallet
        large.wallet = APIAccountWallet(economyVersion: wallet.economyVersion,
            tokenBalance: "9223372036854775807", gemBalance: wallet.gemBalance,
            lifetimeGemsEarned: wallet.lifetimeGemsEarned, initialized: wallet.initialized,
            hostedActive: wallet.hostedActive, hostedOffline: wallet.hostedOffline, hostedTotal: wallet.hostedTotal)
        let proposal = CGSize(width: 280, height: 3000)
        let ordinary = UIHostingController(rootView: ProfileWalletSection(summary: source)
            .environment(\.dynamicTypeSize, .large))
        let overflowing = UIHostingController(rootView: ProfileWalletSection(summary: large)
            .environment(\.dynamicTypeSize, .large))
        let ordinarySize = ordinary.sizeThatFits(in: proposal)
        let largeSize = overflowing.sizeThatFits(in: proposal)
        XCTAssertLessThanOrEqual(largeSize.width, proposal.width + 0.5)
        XCTAssertGreaterThan(largeSize.height, ordinarySize.height,
            "A long wallet balance must switch the pair to a vertical arrangement")

        let shortRecord = UIHostingController(rootView: ProfileRecordRow(title: "Stored visits collected", value: "764")
            .environment(\.dynamicTypeSize, .large))
        let longRecord = UIHostingController(rootView: ProfileRecordRow(title: "Stored visits collected",
            value: "9,223,372,036,854,775,807").environment(\.dynamicTypeSize, .large))
        XCTAssertGreaterThan(longRecord.sizeThatFits(in: proposal).height, shortRecord.sizeThatFits(in: proposal).height,
            "Full record values must move beneath their labels when the row cannot fit")
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

    func testCompactHomeNavigationAndRightActionsUseIndependentSurfaces() async throws {
        let value = try fixture()
        let store = AccountSummaryStore(userID: value.profile.userId, service: PresentationTestService(value: value),
            cache: PresentationTestCache())
        await store.refresh()
        let header = UIHostingController(rootView:
            HomeAccountHeader(store: store, attraction: "141.3", openProfile: { _ in })
                .environment(\.dynamicTypeSize, .large))
        let size = header.sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertGreaterThanOrEqual(size.height, 138)
        XCTAssertLessThanOrEqual(size.height, 142.5, "Balances use one row; Collect and Info stack at the right edge")
        let navigation = UIHostingController(rootView:
            HomeNavigationBar(openProfile: {}, openSettings: {}) {
                HomeLevelProgress(store: store, openProfile: {})
            }.environment(\.dynamicTypeSize, .large))
        let navigationSize = navigation.sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertGreaterThanOrEqual(navigationSize.height, 44)
        XCTAssertLessThanOrEqual(navigationSize.height, 52.5, "Progress, Profile and Settings form one floating row")
        let metrics = UIHostingController(rootView:
            GardenSummaryHeader(tokens: "9,142", attraction: "141.3", stored: "106/1500", gems: "7",
                information: {}, collect: {}).environment(\.dynamicTypeSize, .large))
        XCTAssertLessThanOrEqual(metrics.sizeThatFits(in: CGSize(width: 320, height: 1000)).height, 88.5)
    }

    func testFloatingHomeToolsLeaveTheMiddleOfTheGardenUnobstructed() async throws {
        var frames: [CGRect] = []
        let content = GardenViewportLayout(compact: false) {
            Color.clear
        } status: {
            GardenSummaryHeader(tokens: "9,142", attraction: "141.3", stored: "106/1500", gems: "7",
                floatingActions: true, information: {}, collect: {})
        } controls: { EmptyView() }
        .environment(\.dynamicTypeSize, .large)
        .frame(width: 320, height: 500)
        .onPreferenceChange(GardenOverlayFrames.self) { frames = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if !frames.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.contains { $0.contains(CGPoint(x: 292, y: 116)) }, "Garden info retains its real exclusion bounds")
        XCTAssertTrue(frames.contains { $0.contains(CGPoint(x: 292, y: 68)) }, "Collect retains its real exclusion bounds")
        XCTAssertFalse(frames.contains { $0.contains(CGPoint(x: 160, y: 74)) },
                       "No full-width header exclusion may bridge the two floating controls")
    }

    func testApprovedHomeIconsAreBundledAtRuntimeSize() {
        XCTAssertEqual(Set(HomeNavigationArtwork.images.keys), Set(HomeNavigationArtwork.keys))
        for image in HomeNavigationArtwork.images.values {
            XCTAssertEqual(image.cgImage?.width, 128)
            XCTAssertEqual(image.cgImage?.height, 128)
        }
    }
}
