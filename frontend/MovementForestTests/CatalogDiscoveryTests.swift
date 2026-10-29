import XCTest
import Foundation
@testable import MovementForest

@MainActor
private final class MemoryDiscoveryCache: CatalogDiscoveryPersisting {
    var value: CatalogDiscoveryCache?
    var failSave = false
    func load(server: String, user: UUID) throws -> CatalogDiscoveryCache? { value }
    func save(_ value: CatalogDiscoveryCache, server: String, user: UUID) throws {
        if failSave { throw URLError(.cannotWriteToFile) }
        self.value = value
    }
}

@MainActor
private final class FakeDiscovery: CatalogDiscoveryServing {
    let serverID = "https://discovery-test.invalid"
    var value: APICatalogDiscovery
    var calls = 0
    var fail = false
    var hold = false
    var onSuspended: (() -> Void)?
    var continuation: CheckedContinuation<APICatalogDiscovery, Error>?
    init(_ value: APICatalogDiscovery) { self.value = value }
    func discovery() async throws -> APICatalogDiscovery {
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
final class CatalogDiscoveryTests: XCTestCase {
    private func fixture(_ key: String = "grown") throws -> APICatalogDiscovery {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog-discovery-contract", withExtension: "json", subdirectory: "Fixtures"))
        let values = try ActivityWire.decoder().decode([String: APICatalogDiscovery].self, from: Data(contentsOf: url))
        return try XCTUnwrap(values[key])
    }
    private func revealed(_ store: CatalogDiscoveryStore, _ variant: String, _ stage: GrowthStage) -> Bool {
        store.revealed(species: "oak", variant: variant, stage: stage)
    }

    func testSproutsAlwaysVisibleWhileUnknownFailedOrUnowned() async throws {
        let fresh = try fixture("fresh"), service = FakeDiscovery(try fixture("fresh"))
        let store = CatalogDiscoveryStore(userID: fresh.userId, service: service, cache: MemoryDiscoveryCache())
        XCTAssertTrue(revealed(store, "unowned", .sprout))
        XCTAssertFalse(revealed(store, "standard", .adult))
        service.fail = true
        await store.refresh()
        XCTAssertEqual(store.status(species: "oak", variant: "standard", stage: .adult), "Discovery unavailable")
        XCTAssertTrue(revealed(store, "unowned", .sprout))
        service.fail = false
        await store.refresh()
        XCTAssertEqual(store.status(species: "oak", variant: "standard", stage: .adult), "Not discovered")
    }

    func testExactVariantAndSpeciesIsolationAndPersistentCache() async throws {
        let grown = try fixture(), cache = MemoryDiscoveryCache(), service = FakeDiscovery(try fixture())
        let store = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: cache)
        await store.refresh()
        XCTAssertTrue(revealed(store, "standard", .adult))
        XCTAssertTrue(revealed(store, "blue", .seedling))
        XCTAssertFalse(revealed(store, "blue", .young))
        XCTAssertFalse(revealed(store, "vined", .adult))
        XCTAssertFalse(store.revealed(species: "moonwillow", variant: "standard", stage: .adult))
        let restored = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: cache)
        XCTAssertTrue(revealed(restored, "standard", .adult))
        XCTAssertTrue(restored.lastConfirmed)
        service.fail = true
        await restored.refresh()
        XCTAssertTrue(revealed(restored, "standard", .adult))
        XCTAssertTrue(restored.failed)
    }

    func testWrongAccountAndMalformedStageSnapshotsCannotRevealArt() async throws {
        let grown = try fixture(), service = FakeDiscovery(try fixture()), cache = MemoryDiscoveryCache()
        let wrong = CatalogDiscoveryStore(userID: UUID(), service: service, cache: cache)
        await wrong.refresh()
        XCTAssertNil(wrong.snapshot)
        cache.value = CatalogDiscoveryCache(snapshot: grown, confirmedAt: Date())
        let wrongCache = CatalogDiscoveryStore(userID: UUID(), service: service, cache: cache)
        XCTAssertNil(wrongCache.snapshot)
        let invalidStages: [[GrowthStage]] = [[.sprout], [.adult], [.young, .seedling], [.seedling, .seedling], []]
        for stages in invalidStages {
            let bad = APICatalogDiscovery(userId: grown.userId, catalogVersion: "v", discoveryVersion: 3,
                entries: [.init(speciesId: "oak", variantId: "standard", stages: stages)])
            XCTAssertThrowsError(try bad.validated(user: grown.userId))
        }
    }

    func testOlderVersionsAndInconsistentSnapshotsNeverRelockArt() async throws {
        let grown = try fixture(), service = FakeDiscovery(try fixture())
        let store = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: MemoryDiscoveryCache())
        await store.refresh()
        service.value = try fixture("fresh")
        await store.refresh()
        XCTAssertTrue(revealed(store, "standard", .adult))
        service.value = APICatalogDiscovery(userId: grown.userId, catalogVersion: "v2", discoveryVersion: 3, entries: [])
        await store.refresh()
        XCTAssertTrue(store.failed)
        XCTAssertTrue(revealed(store, "standard", .adult))
        service.value = APICatalogDiscovery(userId: grown.userId, catalogVersion: "v", discoveryVersion: 2, entries: [])
        await store.refresh()
        XCTAssertTrue(store.failed)
        XCTAssertTrue(revealed(store, "standard", .adult))
    }

    func testConcurrentRefreshesCoalesceAndDetachedResponseCannotApply() async throws {
        let grown = try fixture(), service = FakeDiscovery(try fixture())
        service.hold = true
        let store = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: MemoryDiscoveryCache())
        let suspended = expectation(description: "Discovery read is suspended")
        service.onSuspended = { suspended.fulfill() }
        let first = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 5)
        let second = Task { await store.refresh() }
        await Task.yield()
        XCTAssertEqual(service.calls, 1)
        store.deactivate()
        service.continuation?.resume(returning: grown); service.continuation = nil
        await first.value; await second.value
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(revealed(store, "standard", .adult))
    }

    func testGrowthDuringReadRefreshesVisibleCatalogWithoutLosingInvalidation() async throws {
        let grown = try fixture(), fresh = try fixture("fresh"), service = FakeDiscovery(try fixture("fresh"))
        let store = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: MemoryDiscoveryCache())
        store.beginViewing(UUID()); service.hold = true
        let suspended = expectation(description: "Pre-growth discovery read is suspended")
        service.onSuspended = { suspended.fulfill() }
        let first = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 5)
        store.invalidate()
        service.hold = false; service.value = grown
        service.continuation?.resume(returning: fresh); service.continuation = nil
        await first.value
        XCTAssertEqual(service.calls, 2)
        XCTAssertTrue(revealed(store, "standard", .adult))
    }

    func testHiddenGrowthDefersReadAndCacheFailureKeepsVerifiedServerState() async throws {
        let grown = try fixture(), service = FakeDiscovery(try fixture("fresh")), cache = MemoryDiscoveryCache()
        let store = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: cache)
        await store.refresh()
        store.invalidate()
        await Task.yield()
        XCTAssertEqual(service.calls, 1)
        service.value = grown; cache.failSave = true
        await store.refresh()
        XCTAssertTrue(revealed(store, "standard", .adult))
        XCTAssertTrue(store.lastConfirmed)
    }

    func testDiskCacheSeparatesServerAndAccount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = CatalogDiscoveryDiskStore(disk: AccountDiskStore(directory: folder)), grown = try fixture()
        try disk.save(.init(snapshot: grown, confirmedAt: Date()), server: "one", user: grown.userId)
        XCTAssertEqual(try disk.load(server: "one", user: grown.userId)?.snapshot, grown)
        XCTAssertNil(try disk.load(server: "two", user: grown.userId))
        XCTAssertNil(try disk.load(server: "one", user: UUID()))
    }
}
