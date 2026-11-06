import Foundation
import XCTest
@testable import MovementForest

@MainActor
private final class MemoryLevelPresentations: LevelUpPersisting {
    var value: LevelUpPresentationCache?
    var failSave = false
    func load(server: String, user: UUID) throws -> LevelUpPresentationCache? { value }
    func save(_ value: LevelUpPresentationCache) throws {
        if failSave { throw URLError(.cannotWriteToFile) }
        self.value = value
    }
}

@MainActor
private final class FakeLevelClaims: LevelUpServing {
    let notice: APILevelUpNotice
    var allowed = true
    var hold = false
    var requests: [(UUID, UUID)] = []
    var continuation: CheckedContinuation<APILevelUpClaim, Error>?
    var onClaim: (() -> Void)?
    init(_ notice: APILevelUpNotice) { self.notice = notice }
    func claim(notice: UUID, request: UUID, installation: UUID) async throws -> APILevelUpClaim {
        requests.append((request, installation)); onClaim?()
        if hold { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return APILevelUpClaim(notice: self.notice, mayPresent: allowed)
    }
}

@MainActor
final class LevelUpTests: XCTestCase {
    private let owner = UUID()
    private let server = "https://level-presentation.invalid"
    private func notice(from: Int64 = 4, to: Int64 = 5) -> APILevelUpNotice {
        APILevelUpNotice(id: UUID(), policyVersion: "level-benefits-v1", fromLevel: from, toLevel: to,
            baseOfflineBefore: 825, baseOfflineAfter: 900, effectiveOfflineAfter: 1125,
            plantLimitBefore: 50, plantLimitAfter: 60)
    }
    private func coordinator(_ service: FakeLevelClaims, _ cache: MemoryLevelPresentations) -> LevelUpCoordinator {
        LevelUpCoordinator(user: owner, server: server, installation: UUID(), service: service, persistence: cache)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    func testPresentationIsMarkedBeforeShowingAndDoesNotReplayAfterRestart() async {
        let value = notice(), cache = MemoryLevelPresentations()
        let service = FakeLevelClaims(value), first = coordinator(FakeLevelClaims(value), cache)
        first.setEligible(true); first.receive(value)
        await settle()
        XCTAssertEqual(first.presented, value)
        XCTAssertTrue(cache.value?.shown.contains(value.id) == true)
        XCTAssertNil(cache.value?.pending)
        first.dismiss()
        let restored = coordinator(service, cache)
        restored.setEligible(true); restored.receive(value)
        await settle()
        XCTAssertNil(restored.presented)
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testNoticeWaitsForEligibleBrowsing() async {
        let value = notice(), cache = MemoryLevelPresentations()
        let actual = FakeLevelClaims(value), store = coordinator(actual, cache)
        store.receive(value); await settle()
        XCTAssertNil(store.presented); XCTAssertTrue(actual.requests.isEmpty)
        store.setEligible(true); await settle()
        XCTAssertEqual(store.presented, value)
        store.setEligible(false)
        store.setEligible(true); store.receive(value); await settle()
        XCTAssertNil(store.presented)
        XCTAssertEqual(actual.requests.count, 1)
    }

    func testLostEligibilityDuringClaimRecoversOriginalRequest() async {
        let value = notice(), cache = MemoryLevelPresentations()
        let held = FakeLevelClaims(value)
        held.hold = true
        let first = coordinator(held, cache)
        first.receive(value); first.setEligible(true); await settle()
        XCTAssertNotNil(held.continuation)
        first.setEligible(false)
        held.continuation?.resume(returning: APILevelUpClaim(notice: value, mayPresent: true))
        await settle()
        XCTAssertNil(first.presented); XCTAssertNotNil(cache.value?.pending)
        first.deactivate()
        let restoredService = FakeLevelClaims(value), restored = coordinator(restoredService, cache)
        restored.setEligible(true); await settle()
        XCTAssertEqual(restored.presented, value)
        XCTAssertEqual(restoredService.requests.first?.0, held.requests.first?.0)
        XCTAssertEqual(restoredService.requests.first?.1, held.requests.first?.1)
    }

    func testOtherDeviceConsumptionDoesNotPresent() async {
        let value = notice(), cache = MemoryLevelPresentations()
        let denied = FakeLevelClaims(value); denied.allowed = false
        let store = coordinator(denied, cache)
        store.setEligible(true); store.receive(value); await settle()
        XCTAssertNil(store.presented); XCTAssertNil(cache.value?.pending)
    }

    func testDiskFailureAfterClaimCannotMountAndRetriesSameClaim() async {
        let value = notice(), cache = MemoryLevelPresentations()
        let claims = FakeLevelClaims(value)
        claims.onClaim = { cache.failSave = true }
        let store = coordinator(claims, cache)
        store.setEligible(true); store.receive(value); await settle()
        XCTAssertNil(store.presented); XCTAssertNotNil(cache.value?.pending)
        let original = claims.requests.first?.0
        cache.failSave = false; claims.onClaim = nil
        store.receive(value); await settle()
        XCTAssertEqual(store.presented, value)
        XCTAssertEqual(claims.requests.last?.0, original)
    }

    func testDeactivationRejectsLateClaim() async {
        let value = notice(), cache = MemoryLevelPresentations()
        let held = FakeLevelClaims(value); held.hold = true
        let store = coordinator(held, cache)
        store.setEligible(true); store.receive(value); await settle()
        store.deactivate()
        held.continuation?.resume(returning: APILevelUpClaim(notice: value, mayPresent: true))
        await settle()
        XCTAssertNil(store.presented)
        XCTAssertTrue(cache.value?.shown.isEmpty == true)
    }

    func testPresentationCacheCannotCrossAccounts() async {
        let value = notice(), cache = MemoryLevelPresentations()
        cache.value = LevelUpPresentationCache(owner: UUID(), server: server)
        let claims = FakeLevelClaims(value), store = coordinator(claims, cache)
        store.setEligible(true); store.receive(value); await settle()
        XCTAssertNil(store.presented); XCTAssertTrue(claims.requests.isEmpty)
    }

    func testPlantLimitOverridePreservesCountsAndOtherLimits() {
        let original = APIInventoryCapacity(ownedPlants: 50, plantedPlants: 20, storedPlants: 30,
            plantLimit: 50, plantedLimit: 20, unopenedPacks: 12, packLimit: 50)
        let expanded = original.applyingPlantLimit(60)
        XCTAssertEqual(expanded.plantLimit, 60)
        XCTAssertEqual(expanded.ownedPlants, 50)
        XCTAssertEqual(expanded.storedPlants, 30)
        XCTAssertEqual(expanded.plantedLimit, 20)
        XCTAssertEqual(expanded.packLimit, 50)
        XCTAssertFalse(expanded.plantFull)
        XCTAssertEqual(original.applyingPlantLimit(75).applyingPlantLimit(60).plantLimit, 75,
                       "A cached lower level must not overwrite a newer live inventory limit")
    }
}
