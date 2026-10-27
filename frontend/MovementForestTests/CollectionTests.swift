import XCTest
import Foundation
@testable import MovementForest

private struct CollectionContract: Decodable {
    let summary: APICollectionSummary
    let exchange: APICollectionReceipt
    let opening: APICollectionReceipt
    let packs: APIPackPage
    let catalogue: APICatalogue
    static func load(_ name: String = "collection-contract") throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@MainActor
private final class MemoryCollectionJournal: CollectionJournalPersisting {
    var value = CollectionJournalState()
    var failPendingSave = false
    var failCompletionSave = false
    func load(server: String, user: UUID) throws -> CollectionJournalState? { value }
    func save(_ state: CollectionJournalState, server: String, user: UUID) throws {
        if (failPendingSave && state.pending != nil) || (failCompletionSave && state.pending == nil) {
            throw URLError(.cannotWriteToFile)
        }
        value = state
    }
}

@MainActor
private final class FakeCollection: CollectionServing {
    let serverID = "https://collection-test.invalid"
    let contract: CollectionContract
    var operations: [PendingCollectionOperation] = []
    var loseResponse = false
    var reject: APIError?
    var onMutation: (() -> Void)?
    var milestones: [APIIntroMilestone] = []
    var failSummaryAfterMutation = false
    var failSummary = false
    var blockOpening = false
    var openingContinuation: CheckedContinuation<Void, Never>?
    init(_ contract: CollectionContract) { self.contract = contract }
    func summary() async throws -> APICollectionSummary {
        if failSummary { throw URLError(.notConnectedToInternet) }
        if failSummaryAfterMutation && !operations.isEmpty { throw URLError(.networkConnectionLost) }
        var value = contract.summary; value.milestones = milestones; return value
    }
    func catalogue() async throws -> APICatalogue { contract.catalogue }
    func packs(after: UUID?) async throws -> APIPackPage { contract.packs }
    func openings(after: UUID?) async throws -> APIOpeningPage { APIOpeningPage(openings: [contract.opening], nextCursor: nil) }
    func definition(pack: String, version: Int) async throws -> APIPackDefinition {
        try XCTUnwrap(contract.summary.offers.first { $0.pack.packId == pack && $0.pack.version == version }?.pack)
    }
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt {
        try operation.validate(); operations.append(operation); onMutation?()
        if operation.kind == .open && blockOpening {
            await withCheckedContinuation { openingContinuation = $0 }
        }
        if let reject = reject { throw reject }
        if loseResponse { throw URLError(.networkConnectionLost) }
        if operation.kind == .milestone {
            return APICollectionReceipt(requestId: operation.id, tokenBalance: "30", economyVersion: 100,
                milestoneId: operation.milestoneID, milestoneEventId: UUID(), tokensEarned: "30")
        }
        var receipt = operation.kind == .exchange ? contract.exchange : contract.opening
        // Emulate the server's request binding while keeping genuine wire fields.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ActivityWire.encoder().encode(receipt)) as? [String: Any])
        object["requestId"] = operation.id.uuidString
        if operation.kind == .open { object["ownedPackId"] = operation.target!.uuidString }
        receipt = try ActivityWire.decoder().decode(APICollectionReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        return receipt
    }
}

@MainActor
final class CollectionTests: XCTestCase {
    func testRepeatedOpenWhileOriginalRequestIsInFlightKeepsOneOperation() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: journal)
        await store.refresh()
        let pack = try XCTUnwrap(store.packs.first)
        service.blockOpening = true
        let first = Task { await store.open(pack) }
        defer {
            service.blockOpening = false; first.cancel()
            service.openingContinuation?.resume(); service.openingContinuation = nil
        }
        for _ in 0..<100 {
            if service.openingContinuation != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let original = try XCTUnwrap(store.state.pending)
        await store.open(pack)
        XCTAssertEqual(service.operations, [original])
        XCTAssertEqual(store.state.pending, original)
        service.blockOpening = false
        service.openingContinuation?.resume(); service.openingContinuation = nil
        await first.value
        XCTAssertNotNil(store.confirmedOpening(for: pack.id))
        await store.open(pack)
        XCTAssertEqual(service.operations, [original])
    }

    func testKnownOpeningFromHistoryNeverSubmitsAnotherRequest() async throws {
        let fixture = try CollectionContract.load(), service = FakeCollection(try CollectionContract.load())
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: MemoryCollectionJournal())
        await store.refresh()
        let pack = try XCTUnwrap(fixture.exchange.packs?.first)
        XCTAssertNotNil(store.confirmedOpening(for: pack.id))
        await store.open(pack)
        XCTAssertTrue(service.operations.isEmpty)
        XCTAssertNil(store.state.pending)
    }

    func testReopenedUnknownOpeningRecoversOriginalUUIDAndBody() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let user = UUID(), store = CollectionCoordinator(userID: user, service: service, journal: journal)
        await store.refresh()
        let pack = try XCTUnwrap(store.packs.first)
        service.loseResponse = true; await store.open(pack)
        let pending = try XCTUnwrap(store.state.pending)
        let reopened = CollectionCoordinator(userID: user, service: service, journal: journal)
        service.loseResponse = false
        await reopened.open(pack)
        XCTAssertEqual(service.operations.count, 2)
        XCTAssertEqual(service.operations[0], pending); XCTAssertEqual(service.operations[1], pending)
        XCTAssertNil(reopened.state.pending)
        let result = try XCTUnwrap(reopened.confirmedOpening(for: pack.id))
        XCTAssertNotNil(result.plant)
        await reopened.open(pack)
        XCTAssertEqual(service.operations.count, 2)
        XCTAssertEqual(reopened.confirmedOpening(for: pack.id)?.openingId, result.openingId)
    }

    func testMilestoneConfirmationSurvivesRefreshFailureAndStaleRepeatedClaim() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let milestone = APIIntroMilestone(milestoneId: "first_movement", title: "First movement",
            description: "Sync movement.", rewardTokens: "30", eligible: true, claimed: false)
        service.milestones = [milestone]
        let user = UUID(), store = CollectionCoordinator(userID: user, service: service, journal: journal)
        await store.refresh()
        XCTAssertNotNil(store.milestonesConfirmedAt)
        service.failSummaryAfterMutation = true
        await store.claim(milestone)
        XCTAssertTrue(store.refreshFailed)
        XCTAssertEqual(store.tokenBalance, "30")
        XCTAssertTrue(store.confirmedMilestoneIDs.contains(milestone.id))
        XCTAssertNil(store.state.pending)
        await store.claim(milestone)
        XCTAssertEqual(service.operations.count, 1)
        store.deactivate()
        let reopened = CollectionCoordinator(userID: user, service: service, journal: journal)
        XCTAssertTrue(reopened.confirmedMilestoneIDs.contains(milestone.id))
        await reopened.refresh()
        XCTAssertTrue(reopened.refreshFailed)
        XCTAssertEqual(service.operations.count, 1)
    }

    func testMilestoneRefreshFailureKeepsLastConfirmedRowsAndCanRecover() async throws {
        let service = FakeCollection(try CollectionContract.load())
        service.failSummary = true
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: MemoryCollectionJournal())
        await store.refresh()
        XCTAssertTrue(store.refreshFailed)
        XCTAssertNil(store.milestonesConfirmedAt)
        service.failSummary = false
        service.milestones = [APIIntroMilestone(milestoneId: "first_movement", title: "First movement",
            description: "Sync movement.", rewardTokens: "30", eligible: false, claimed: false)]
        await store.refresh()
        let confirmedAt = store.milestonesConfirmedAt
        XCTAssertNotNil(confirmedAt)
        XCTAssertFalse(store.refreshFailed)
        service.failSummary = true
        await store.refresh()
        XCTAssertTrue(store.refreshFailed)
        XCTAssertEqual(store.milestonesConfirmedAt, confirmedAt)
        XCTAssertEqual(store.milestones.first?.title, "First movement")
        await store.claim(try XCTUnwrap(store.milestones.first))
        XCTAssertTrue(service.operations.isEmpty)
        service.failSummary = false
        await store.refresh()
        XCTAssertFalse(store.refreshFailed)
    }

    func testConfirmedExchangeSurvivesFailureOfTheFollowingRefresh() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: journal)
        await store.refresh()
        service.failSummaryAfterMutation = true
        await store.exchange(try XCTUnwrap(store.offers.first), quantity: 1)
        XCTAssertNil(store.state.pending)
        XCTAssertNotNil(store.confirmedExchange?.exchangeId)
        XCTAssertTrue(store.exchangeMessage?.contains("Purchase confirmed") == true)
        XCTAssertEqual(service.operations.count, 1)
        XCTAssertEqual(store.confirmedExchange?.id, journal.value.result?.id)
    }

    func testMilestoneLostResponseRetainsClaimBytesAndRecoversAfterRelaunch() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        service.milestones = [APIIntroMilestone(milestoneId: "first_movement", title: "First movement",
            description: "Sync movement.", rewardTokens: "30", eligible: true, claimed: false)]
        let user = UUID(), first = CollectionCoordinator(userID: user, service: service, journal: journal)
        await first.refresh()
        service.loseResponse = true
        await first.claim(try XCTUnwrap(first.milestones.first))
        let saved = try XCTUnwrap(journal.value.pending)
        XCTAssertEqual(saved.kind, .milestone)
        XCTAssertEqual(saved.milestoneID, "first_movement")
        first.deactivate(); service.loseResponse = false
        let reopened = CollectionCoordinator(userID: user, service: service, journal: journal)
        await reopened.refresh()
        XCTAssertEqual(service.operations[0], service.operations[1])
        XCTAssertEqual(service.operations.last?.body, saved.body)
        XCTAssertNil(reopened.state.pending)
        XCTAssertEqual(reopened.state.result?.tokensEarned, "30")
        XCTAssertEqual(reopened.tokenBalance, "30")
    }

    func testRealWireContractAndCatalogueStats() throws {
        let contract = try CollectionContract.load()
        XCTAssertEqual(contract.exchange.packs?.count, 2)
        XCTAssertEqual(contract.opening.plant?.growthStage, .sprout)
        XCTAssertEqual(contract.opening.plant?.growthMicroUnits, "0")
        XCTAssertNil(contract.opening.plant?.placement)
        XCTAssertNotNil(contract.catalogue.profiles?["growth"]?.first?.thresholdsMicroUnits)
        XCTAssertNotNil(contract.catalogue.profiles?["behaviour"]?.first?.metricMultipliers?["steps"])
        let pack = try XCTUnwrap(contract.summary.offers.first { $0.offerId == "woodland" }?.pack)
        XCTAssertEqual(pack.rarities.reduce(0) { $0 + $1.weight }, pack.totalWeight)
        XCTAssertEqual(pack.schemaVersion, 2)
        XCTAssertEqual(pack.rarities.first { $0.rarity == "common" }?.weight, 100)
        XCTAssertEqual(contract.catalogue.species.count, 2)
        let oak = try XCTUnwrap(pack.speciesOdds.first { $0.speciesId == "oak" })
        let moon = try XCTUnwrap(pack.speciesOdds.first { $0.speciesId == "moonwillow" })
        XCTAssertEqual(oak.withinRarity, 0.5)
        XCTAssertEqual(moon.withinRarity, 0.5)
        XCTAssertEqual(oak.variants.first { $0.variantId == "blue" }?.conditional, 0.2)
        XCTAssertEqual(oak.variants.first { $0.variantId == "blue" }?.overall, 0.1)
        XCTAssertEqual(moon.variants.first { $0.variantId == "golden" }?.overall, 0.05)
    }

    func testLegacyPackProbabilitiesRemainReadable() throws {
        let legacy = try CollectionContract.load("collection-contract-v1")
        let pack = try XCTUnwrap(legacy.summary.offers.first { $0.offerId == "woodland" }?.pack)
        XCTAssertEqual(pack.schemaVersion, 1)
        XCTAssertEqual(pack.speciesOdds.first { $0.rarity == "rare" }?.overall, 0.2)
        XCTAssertEqual(pack.speciesOdds.first { $0.rarity == "common" }?.variants.first?.conditional, 1)
    }

    func testVariantCountCannotInflateDisplayedSpeciesOdds() throws {
        let contract = try CollectionContract.load()
        let pack = try XCTUnwrap(contract.summary.offers.first { $0.offerId == "woodland" }?.pack)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ActivityWire.encoder().encode(pack)) as? [String: Any])
        var rarities = try XCTUnwrap(object["rarities"] as? [[String: Any]])
        var species = try XCTUnwrap(rarities[0]["species"] as? [[String: Any]])
        let index = try XCTUnwrap(species.firstIndex { $0["speciesId"] as? String == "oak" })
        var variants = try XCTUnwrap(species[index]["variants"] as? [[String: Any]])
        var extra = variants[0]; extra["variantId"] = "extra"; extra["weight"] = 40
        variants.append(extra); species[index]["variants"] = variants
        rarities[0]["species"] = species; object["rarities"] = rarities
        let revised = try ActivityWire.decoder().decode(APIPackDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(revised.speciesOdds.first { $0.speciesId == "oak" }?.overall, 0.5)
        XCTAssertEqual(revised.speciesOdds.first { $0.speciesId == "moonwillow" }?.overall, 0.5)
    }

    func testLostExchangeResponseRelaunchReplaysExactBytesAndUUID() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let user = UUID(), first = CollectionCoordinator(userID: user, service: service, journal: journal)
        await first.refresh()
        service.loseResponse = true
        await first.exchange(try XCTUnwrap(first.offers.first), quantity: 1)
        let saved = try XCTUnwrap(journal.value.pending)
        first.deactivate(); service.loseResponse = false
        let reopened = CollectionCoordinator(userID: user, service: service, journal: journal)
        await reopened.refresh()
        XCTAssertEqual(service.operations.count, 2)
        XCTAssertEqual(service.operations[0], service.operations[1])
        XCTAssertEqual(service.operations.last?.body, saved.body)
        XCTAssertNil(reopened.state.pending)
        XCTAssertNotNil(reopened.state.result?.exchangeId)
    }

    func testCannotSendIfDurableSaveFails() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: journal)
        await store.refresh(); journal.failPendingSave = true
        await store.exchange(try XCTUnwrap(store.offers.first), quantity: 1)
        XCTAssertTrue(service.operations.isEmpty)
        XCTAssertNil(store.state.pending)
    }

    func testCompletionDiskFailureRetainsRequestAndOpeningResultSurvivesRelaunch() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let user = UUID(), store = CollectionCoordinator(userID: user, service: service, journal: journal)
        await store.refresh(); journal.failCompletionSave = true
        await store.open(try XCTUnwrap(store.packs.first))
        let pending = try XCTUnwrap(store.state.pending)
        journal.failCompletionSave = false
        await store.refresh()
        XCTAssertEqual(service.operations.last?.id, pending.id)
        XCTAssertNotNil(store.state.result?.plant)
        let reopened = CollectionCoordinator(userID: user, service: service, journal: journal)
        XCTAssertEqual(reopened.state.result?.plant?.plantId, store.state.result?.plant?.plantId)
    }

    func testDefinitiveRejectionClearsOperationAndAuthFailureKeepsIt() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: journal)
        await store.refresh()
        service.reject = APIError(status: 401, code: "session_required", message: "Sign in again")
        await store.exchange(try XCTUnwrap(store.offers.first), quantity: 1)
        XCTAssertNotNil(store.state.pending)
        service.reject = APIError(status: 409, code: "stale_offer", message: "Refresh Exchange")
        await store.refresh()
        XCTAssertNil(store.state.pending)
    }

    func testLateDetachedResponseCannotGrantToAnotherAccount() async throws {
        let service = FakeCollection(try CollectionContract.load()), journal = MemoryCollectionJournal()
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: journal)
        await store.refresh()
        service.onMutation = { store.deactivate() }
        await store.exchange(try XCTUnwrap(store.offers.first), quantity: 1)
        XCTAssertNotNil(journal.value.pending)
        XCTAssertNil(journal.value.result)
    }

    func testOldReceiptsCannotRewindConfirmedWalletAndCallbacksDoNotLoop() throws {
        let service = FakeCollection(try CollectionContract.load())
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: MemoryCollectionJournal())
        var updates = 0
        store.onWallet = { balance, version in updates += 1; store.applyWallet(balance, version: version) }
        store.applyWallet("20", version: 4)
        store.applyWallet("100", version: 2)
        XCTAssertEqual(store.tokenBalance, "20")
        XCTAssertEqual(updates, 1)
    }

    func testJournalRejectsTamperingAndSeparatesAccountScopes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CollectionJournalStore(disk: AccountDiskStore(directory: directory))
        let user = UUID(), request = UUID()
        let body = try ActivityWire.encoder().encode(CollectionOpenBody(requestId: request))
        let invalid = PendingCollectionOperation(id: UUID(), kind: .open, target: UUID(), body: body)
        XCTAssertThrowsError(try journal.save(CollectionJournalState(pending: invalid), server: "one", user: user))
        let operation = PendingCollectionOperation(id: request, kind: .open, target: UUID(), body: body)
        try journal.save(CollectionJournalState(pending: operation), server: "one", user: user)
        XCTAssertNil(try journal.load(server: "two", user: user))
        XCTAssertNil(try journal.load(server: "one", user: UUID()))
        XCTAssertEqual(try journal.load(server: "one", user: user)?.pending?.body, body)
    }
}
