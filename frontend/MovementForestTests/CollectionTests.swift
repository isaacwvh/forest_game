import XCTest
import Foundation
@testable import MovementForest

private struct CollectionContract: Decodable {
    let summary: APICollectionSummary
    let exchange: APICollectionReceipt
    let opening: APICollectionReceipt
    let packs: APIPackPage
    let catalogue: APICatalogue
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "collection-contract", withExtension: "json", subdirectory: "Fixtures"))
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
    init(_ contract: CollectionContract) { self.contract = contract }
    func summary() async throws -> APICollectionSummary { contract.summary }
    func catalogue() async throws -> APICatalogue { contract.catalogue }
    func packs(after: UUID?) async throws -> APIPackPage { contract.packs }
    func openings(after: UUID?) async throws -> APIOpeningPage { APIOpeningPage(openings: [contract.opening], nextCursor: nil) }
    func definition(pack: String, version: Int) async throws -> APIPackDefinition {
        try XCTUnwrap(contract.summary.offers.first { $0.pack.packId == pack && $0.pack.version == version }?.pack)
    }
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt {
        try operation.validate(); operations.append(operation); onMutation?()
        if let reject = reject { throw reject }
        if loseResponse { throw URLError(.networkConnectionLost) }
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
        XCTAssertEqual(pack.rarities.first { $0.rarity == "rare" }?.weight, 20)
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
