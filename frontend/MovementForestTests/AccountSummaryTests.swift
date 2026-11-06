import Foundation
import XCTest
@testable import MovementForest

@MainActor
private final class MemoryAccountSummaryCache: AccountSummaryPersisting {
    var value: AccountSummaryCache?
    var failSave = false
    func load(server: String, user: UUID) throws -> AccountSummaryCache? { value }
    func save(_ value: AccountSummaryCache, server: String, user: UUID) throws {
        if failSave { throw URLError(.cannotWriteToFile) }
        self.value = value
    }
}

@MainActor
private final class FakeAccountSummary: AccountSummaryServing {
    let serverID = "https://account-test.invalid"
    var value: APIAccountSummary
    var calls = 0
    var fail = false
    var hold = false
    var onSuspended: (() -> Void)?
    var continuation: CheckedContinuation<APIAccountSummary, Error>?
    init(_ value: APIAccountSummary) { self.value = value }
    func accountSummary() async throws -> APIAccountSummary {
        calls += 1
        if fail { throw URLError(.notConnectedToInternet) }
        if hold {
            return try await withCheckedThrowingContinuation {
                continuation = $0; onSuspended?()
            }
        }
        return value
    }
}

@MainActor
final class AccountSummaryTests: XCTestCase {
    private func fixture(_ key: String = "grown") throws -> APIAccountSummary {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "account-summary-contract", withExtension: "json", subdirectory: "Fixtures"))
        let values = try ActivityWire.decoder().decode([String: APIAccountSummary].self, from: Data(contentsOf: url))
        return try XCTUnwrap(values[key])
    }

    func testRealBackendContractAndProgress() throws {
        let value = try fixture()
        XCTAssertNoThrow(try value.validated(user: value.profile.userId))
        XCTAssertEqual(value.wallet.gemBalance, "3")
        XCTAssertEqual(value.progression.level, 5)
        XCTAssertEqual(value.progression.xpIntoLevel, "22")
        XCTAssertEqual(value.progression.xpForNextLevel, "150")
        XCTAssertEqual(value.progression.stepsIntoNextGem, 7250)
        XCTAssertEqual(value.progression.stepsToNextGem, 2750)
    }

    func testCachedStateSurvivesOfflineRefresh() async throws {
        let value = try fixture(), service = FakeAccountSummary(try fixture())
        let cache = MemoryAccountSummaryCache()
        let store = AccountSummaryStore(userID: value.profile.userId, service: service, cache: cache)
        await store.refresh()
        XCTAssertEqual(store.snapshot, value)
        XCTAssertFalse(store.lastConfirmed)
        let restored = AccountSummaryStore(userID: value.profile.userId, service: service, cache: cache)
        XCTAssertEqual(restored.snapshot, value)
        XCTAssertTrue(restored.lastConfirmed)
        XCTAssertTrue(restored.showsSavedProgress)
        service.fail = true
        await store.refresh()
        XCTAssertTrue(store.failed)
        XCTAssertEqual(store.snapshot, value)
        await restored.refresh()
        XCTAssertTrue(restored.failed)
        XCTAssertEqual(restored.snapshot, value)
    }

    func testWrongAccountResponsesAndCacheAreRejected() async throws {
        let value = try fixture(), service = FakeAccountSummary(try fixture())
        let cache = MemoryAccountSummaryCache()
        cache.value = AccountSummaryCache(snapshot: value, confirmedAt: Date())
        let store = AccountSummaryStore(userID: UUID(), service: service, cache: cache)
        XCTAssertNil(store.snapshot)
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.failed)
    }

    func testWarmRewardRefreshDoesNotFlashSavedProgress() async throws {
        let fresh = try fixture("fresh"), grown = try fixture()
        let service = FakeAccountSummary(fresh)
        let store = AccountSummaryStore(userID: fresh.profile.userId, service: service, cache: MemoryAccountSummaryCache())
        await store.refresh()
        service.hold = true; service.value = grown
        let suspended = expectation(description: "reward wallet refresh suspended")
        service.onSuspended = { suspended.fulfill() }
        store.economyChanged(grown.wallet.economyVersion)
        XCTAssertTrue(store.lastConfirmed)
        XCTAssertFalse(store.showsSavedProgress, "Queued reward refresh must stay quiet before its task starts")
        await fulfillment(of: [suspended], timeout: 2)
        XCTAssertTrue(store.refreshing)
        XCTAssertFalse(store.showsSavedProgress)
        service.continuation?.resume(returning: grown)
        await store.refresh()
        XCTAssertFalse(store.lastConfirmed)
        XCTAssertFalse(store.showsSavedProgress)
        XCTAssertEqual(store.snapshot, grown)
    }

    func testRestoredCacheStaysLabelledDuringItsFirstRead() async throws {
        let value = try fixture(), cache = MemoryAccountSummaryCache()
        cache.value = AccountSummaryCache(snapshot: value, confirmedAt: Date())
        let service = FakeAccountSummary(value)
        service.hold = true
        let suspended = expectation(description: "restored account read suspended")
        service.onSuspended = { suspended.fulfill() }
        let store = AccountSummaryStore(userID: value.profile.userId, service: service, cache: cache)
        XCTAssertTrue(store.showsSavedProgress)
        let read = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 2)
        XCTAssertTrue(store.showsSavedProgress)
        service.continuation?.resume(returning: value)
        await read.value
        XCTAssertFalse(store.showsSavedProgress)
    }

    func testCachedOnlyRepositoryRestoresBeforeRemoteIdentityVerification() async throws {
        let value = try fixture(), cache = MemoryAccountSummaryCache()
        cache.value = AccountSummaryCache(snapshot: value, confirmedAt: Date())
        let store = AccountSummaryStore(userID: value.profile.userId,
            service: UnavailableAccountSummaryRepository(serverID: "https://account-test.invalid"), cache: cache)
        XCTAssertEqual(store.snapshot, value)
        await store.refresh()
        XCTAssertEqual(store.snapshot, value)
        XCTAssertTrue(store.lastConfirmed)
    }

    func testRealDiskCacheRefreshDoesNotConflictWithItsServerVersion() async throws {
        let value = try fixture(), service = FakeAccountSummary(try fixture())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AccountSummaryDiskStore(disk: AccountDiskStore(directory: directory))
        let first = AccountSummaryStore(userID: value.profile.userId, service: service, cache: cache)
        await first.refresh()
        let restored = AccountSummaryStore(userID: value.profile.userId, service: service, cache: cache)
        XCTAssertNotNil(restored.snapshot)
        await restored.refresh()
        XCTAssertFalse(restored.failed)
        XCTAssertFalse(restored.lastConfirmed)
        XCTAssertEqual(restored.snapshot?.progression.totalXp, value.progression.totalXp)
    }

    func testOlderReceiptAndReadCannotRewindProgressOrWallet() async throws {
        let grown = try fixture(), fresh = try fixture("fresh")
        let service = FakeAccountSummary(grown)
        let store = AccountSummaryStore(userID: grown.profile.userId, service: service, cache: MemoryAccountSummaryCache())
        var versions: [Int64] = []
        store.onWallet = { _, version in versions.append(version) }
        await store.refresh()
        service.value = fresh
        store.receive(progression: fresh.progression, wallet: fresh.wallet)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.progression, grown.progression)
        XCTAssertEqual(store.snapshot?.wallet, grown.wallet)
        XCTAssertTrue(store.lastConfirmed)
        XCTAssertTrue(store.showsSavedProgress, "An obsolete response must still identify stale values")
        XCTAssertEqual(versions, [grown.wallet.economyVersion])
    }

    func testConflictingSameVersionCannotChangeBalance() async throws {
        let value = try fixture(), service = FakeAccountSummary(try fixture())
        let store = AccountSummaryStore(userID: value.profile.userId, service: service, cache: MemoryAccountSummaryCache())
        await store.refresh()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ActivityWire.encoder().encode(value)) as? [String: Any])
        var wallet = try XCTUnwrap(object["wallet"] as? [String: Any])
        wallet["tokenBalance"] = "999"
        object["wallet"] = wallet
        service.value = try ActivityWire.decoder().decode(APIAccountSummary.self, from: JSONSerialization.data(withJSONObject: object))
        await store.refresh()
        XCTAssertEqual(store.snapshot?.wallet, value.wallet)
        XCTAssertTrue(store.failed)
    }

    func testMissingLegacyProgressionRefreshesCurrentState() async throws {
        let grown = try fixture(), service = FakeAccountSummary(try fixture("fresh"))
        let store = AccountSummaryStore(userID: grown.profile.userId, service: service, cache: MemoryAccountSummaryCache())
        await store.refresh()
        service.value = grown
        store.receive(progression: nil, wallet: nil)
        await store.refresh()
        XCTAssertEqual(store.snapshot, grown)
    }

    func testInvalidationDuringFetchIsCoalescedAndRefetched() async throws {
        let grown = try fixture(), fresh = try fixture("fresh")
        let service = FakeAccountSummary(fresh)
        service.hold = true
        let suspended = expectation(description: "summary read suspended")
        service.onSuspended = { suspended.fulfill() }
        let store = AccountSummaryStore(userID: grown.profile.userId, service: service, cache: MemoryAccountSummaryCache())
        let first = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 2)
        let second = Task { await store.refresh() }
        store.economyChanged(grown.wallet.economyVersion)
        service.hold = false; service.value = grown
        service.continuation?.resume(returning: fresh)
        await first.value; await second.value
        XCTAssertEqual(service.calls, 2)
        XCTAssertEqual(store.snapshot, grown)
        XCTAssertFalse(store.lastConfirmed)
    }

    func testDetachRejectsLateResponse() async throws {
        let value = try fixture(), service = FakeAccountSummary(try fixture())
        service.hold = true
        let suspended = expectation(description: "summary read suspended")
        service.onSuspended = { suspended.fulfill() }
        let store = AccountSummaryStore(userID: value.profile.userId, service: service, cache: MemoryAccountSummaryCache())
        let work = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 2)
        store.deactivate()
        service.continuation?.resume(returning: value)
        await work.value
        XCTAssertNil(store.snapshot)
    }

    func testCacheWriteFailureKeepsConfirmedServerStateUsable() async throws {
        let value = try fixture(), service = FakeAccountSummary(try fixture())
        let cache = MemoryAccountSummaryCache(); cache.failSave = true
        let store = AccountSummaryStore(userID: value.profile.userId, service: service, cache: cache)
        await store.refresh()
        XCTAssertEqual(store.snapshot, value)
        XCTAssertFalse(store.failed)
    }

    func testMalformedProgressionIsRejected() throws {
        let value = try fixture()
        let data = try ActivityWire.encoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var progression = try XCTUnwrap(object["progression"] as? [String: Any])
        progression["xpIntoLevel"] = "999999"
        object["progression"] = progression
        let invalid = try ActivityWire.decoder().decode(APIAccountSummary.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try invalid.validated(user: value.profile.userId))
    }
}
