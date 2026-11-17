import XCTest
import Foundation
import SwiftUI
import UIKit
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

    func testRoutineDiscoveryInvalidationDoesNotFlashSavedDataNotice() async throws {
        let value = try fixture(), service = FakeDiscovery(try fixture())
        let store = CatalogDiscoveryStore(userID: value.userId, service: service, cache: MemoryDiscoveryCache())
        await store.refresh()
        XCTAssertFalse(store.showsSavedDiscovery)
        service.hold = true
        let suspended = expectation(description: "Routine discovery refresh suspended")
        service.onSuspended = { suspended.fulfill() }
        store.invalidate()
        XCTAssertTrue(store.lastConfirmed)
        XCTAssertFalse(store.showsSavedDiscovery)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 5)
        XCTAssertTrue(store.refreshing)
        XCTAssertFalse(store.showsSavedDiscovery)
        service.continuation?.resume(returning: value); service.continuation = nil
        await refresh.value
        XCTAssertFalse(store.showsSavedDiscovery)
    }

    func testRestoredDiscoveryStaysLabelledUntilLiveConfirmation() async throws {
        let value = try fixture(), service = FakeDiscovery(try fixture()), cache = MemoryDiscoveryCache()
        cache.value = CatalogDiscoveryCache(snapshot: value, confirmedAt: Date())
        let store = CatalogDiscoveryStore(userID: value.userId, service: service, cache: cache)
        XCTAssertTrue(store.showsSavedDiscovery)
        service.hold = true
        let suspended = expectation(description: "Restored discovery refresh suspended")
        service.onSuspended = { suspended.fulfill() }
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [suspended], timeout: 5)
        XCTAssertTrue(store.showsSavedDiscovery)
        service.continuation?.resume(returning: value); service.continuation = nil
        await refresh.value
        XCTAssertFalse(store.showsSavedDiscovery)
        cache.failSave = true
        service.hold = false
        await store.refresh()
        XCTAssertTrue(store.showsSavedDiscovery, "A failed cache save must keep verified data labelled")
    }

    func testCollectionProgressSurvivesCachedFailuresAndClearsOnAccountDetach() async throws {
        let grown = try fixture(), cache = MemoryDiscoveryCache(), service = FakeDiscovery(try fixture())
        let catalogue = APICatalogue(catalogVersion: grown.catalogVersion, isFixture: true, coordinateUnit: "garden_unit",
            gardenUnitMetres: 1, coordinateDecimalPlaces: 3, rotationDecimalPlaces: 2,
            species: [APISpecies(speciesId: "oak", displayName: "Oak", clearanceRadius: 1,
                variants: ["standard", "blue", "vined"].map {
                    APIVariant(variantId: $0, displayName: $0, assetCatalogVersion: "1", stages: [:])
                })])
        let store = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: cache)
        XCTAssertNil(CatalogCollectionCounts(catalogue: catalogue, discovery: store.snapshot))
        await store.refresh()
        let confirmed = try XCTUnwrap(CatalogCollectionCounts(catalogue: catalogue, discovery: store.snapshot))
        XCTAssertEqual(confirmed.collectedPlants, 1)
        XCTAssertEqual(confirmed.collectedVariants, 1)
        let restored = CatalogDiscoveryStore(userID: grown.userId, service: service, cache: cache)
        XCTAssertEqual(CatalogCollectionCounts(catalogue: catalogue, discovery: restored.snapshot), confirmed)
        service.fail = true
        await restored.refresh()
        XCTAssertEqual(CatalogCollectionCounts(catalogue: catalogue, discovery: restored.snapshot), confirmed)
        // Both the unknown and saved-data states fit without clipping at the largest text size.
        for width: CGFloat in [232, 302] {
            for textSize: DynamicTypeSize in [.large, .xxxLarge, .accessibility5] {
                for current in [restored, CatalogDiscoveryStore(userID: UUID(), service: service, cache: MemoryDiscoveryCache())] {
                    let host = UIHostingController(rootView: CatalogCollectionTracker(catalogue: catalogue, discovery: current)
                        .environment(\.dynamicTypeSize, textSize))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                    XCTAssertLessThanOrEqual(size.width, width + 1)
                    XCTAssertTrue(size.height.isFinite)
                    XCTAssertGreaterThan(size.height, 44)
                }
            }
        }
        restored.deactivate()
        XCTAssertNil(CatalogCollectionCounts(catalogue: catalogue, discovery: restored.snapshot))
    }

    func testUnownedSproutsStayConcealedWhileUnknownFailedOrConfirmed() async throws {
        let fresh = try fixture("fresh"), service = FakeDiscovery(try fixture("fresh"))
        let store = CatalogDiscoveryStore(userID: fresh.userId, service: service, cache: MemoryDiscoveryCache())
        XCTAssertFalse(revealed(store, "unowned", .sprout))
        XCTAssertFalse(revealed(store, "standard", .adult))
        service.fail = true
        await store.refresh()
        XCTAssertEqual(store.status(species: "oak", variant: "standard", stage: .adult), "Discovery unavailable")
        XCTAssertFalse(revealed(store, "unowned", .sprout))
        service.fail = false
        await store.refresh()
        XCTAssertEqual(store.status(species: "oak", variant: "standard", stage: .adult), "Not discovered")
        XCTAssertFalse(revealed(store, "unowned", .sprout))
        service.value = try fixture("grown")
        await store.refresh()
        XCTAssertTrue(revealed(store, "standard", .sprout))
        XCTAssertTrue(revealed(store, "blue", .sprout))
        XCTAssertFalse(revealed(store, "vined", .sprout))
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
        let invalidStages: [[GrowthStage]] = [[.seedling], [.adult], [.young, .seedling], [.sprout, .sprout], []]
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

    func testLegacyCachePreservesEarnedStagesWithoutRestoringFreeSproutPreviews() throws {
        let user = UUID()
        let legacy = APICatalogDiscovery(userId: user, catalogVersion: "legacy", discoveryVersion: 2,
            entries: [.init(speciesId: "oak", variantId: "blue", stages: [.seedling, .young])])
        var saved = CatalogDiscoveryCache(snapshot: legacy, confirmedAt: Date())
        saved.artworkPolicyVersion = nil
        // Exercise decoding a pre-policy cache, where the field was absent.
        let data = try ActivityWire.encoder().encode(saved)
        let decoded = try ActivityWire.decoder().decode(CatalogDiscoveryCache.self, from: data)
        let upgraded = try decoded.upgraded(user: user)
        XCTAssertEqual(upgraded.artworkPolicyVersion, 2)
        XCTAssertEqual(upgraded.snapshot.entries[0].stages, [.sprout, .seedling, .young])
        XCTAssertFalse(upgraded.snapshot.keys.contains(.init(species: "oak", variant: "standard", stage: .sprout)))
        XCTAssertThrowsError(try decoded.upgraded(user: UUID()))
        XCTAssertEqual(try upgraded.upgraded(user: user).snapshot, upgraded.snapshot)
    }
}
