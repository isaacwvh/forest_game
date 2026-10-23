import XCTest
import Foundation
@testable import MovementForest

private struct VisitorContract: Decodable {
    let initial: APIVisitorSummary
    let active: APIVisitorSummary
    let welcome: APIVisitorReward
    let stored: APIVisitorSummary
    let claim: APIVisitorReward
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "visitor-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private func changed(_ summary: APIVisitorSummary, _ changes: [String: Any]) throws -> APIVisitorSummary {
    let data = try ActivityWire.encoder().encode(summary)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    changes.forEach { object[$0.key] = $0.value }
    return try ActivityWire.decoder().decode(APIVisitorSummary.self, from: JSONSerialization.data(withJSONObject: object))
}

@MainActor
private final class MemoryVisitorJournal: VisitorJournalPersisting {
    var value: PendingVisitorOperation?
    var failSave = false
    var failRemoval = false
    func load(server: String, user: UUID) throws -> PendingVisitorOperation? { value }
    func save(_ value: PendingVisitorOperation?, server: String, user: UUID) throws {
        if failSave || (value == nil && failRemoval) { throw URLError(.cannotWriteToFile) }
        self.value = value
    }
}

@MainActor
private final class FakeVisitors: VisitorServing {
    let serverID = "https://visitor-test.invalid/"
    let contract: VisitorContract
    var current: APIVisitorSummary
    var operations: [PendingVisitorOperation] = []
    var offline = false
    var onMutation: (() -> Void)?
    init(_ contract: VisitorContract) { self.contract = contract; current = contract.initial }
    func read() async throws -> APIVisitorSummary {
        if offline { throw URLError(.notConnectedToInternet) }
        return current
    }
    func mutate(_ operation: PendingVisitorOperation) async throws -> (APIVisitorSummary, APIVisitorReward?) {
        try operation.validate(); operations.append(operation); onMutation?()
        if offline { throw URLError(.networkConnectionLost) }
        switch operation.kind {
        case .start: current = contract.active; return (current, nil)
        case .heartbeat: return (current, nil)
        case .end:
            current = try changed(current, ["session": NSNull(), "opportunities": [], "version": current.version + 1])
            return (current, nil)
        case .welcome: current = contract.welcome.summary; return (current, contract.welcome)
        case .claim: current = contract.claim.summary; return (current, contract.claim)
        }
    }
}

@MainActor
final class VisitorTests: XCTestCase {
    func testDefaultJournalIsConstructedInsideMainActorInitializer() throws {
        let fixture = try VisitorContract.load()
        // Exercise the same omitted-journal call used by GardenConnection.
        // A unique user only reads a missing journal; no account files are written.
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: FakeVisitors(fixture))
        XCTAssertFalse(store.recoveryLocked)
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.pending)
        XCTAssertNil(store.summary)
    }

    func testActualHTTPWireContractAndFractions() throws {
        let fixture = try VisitorContract.load()
        XCTAssertEqual(fixture.initial.tokenBalance, "0")
        XCTAssertEqual(fixture.active.opportunities.count, 1)
        XCTAssertEqual(fixture.welcome.summary.hostedActive, "1")
        XCTAssertEqual(fixture.claim.summary.tokenBalance, "3")
        XCTAssertEqual(fixture.claim.summary.storedVisitsMicroUnits, "500000")
        XCTAssertEqual(fixture.claim.summary.hostedTotal, "3")
    }

    func testActiveSessionAndPauseEndThroughSameCoordinator() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId), service: service, journal: MemoryVisitorJournal())
        store.setEligible(true, reconcile: false)
        await store.tick(force: true)
        XCTAssertNotNil(store.visibleOpportunity)
        await store.pause()
        XCTAssertNil(store.visibleOpportunity)
        XCTAssertNil(store.summary?.session)
        XCTAssertEqual(service.operations.map(\.kind), [.start, .end])
    }

    func testPauseWhileStartIsInFlightImmediatelyEndsReturnedSession() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId), service: service, journal: MemoryVisitorJournal())
        store.setEligible(true, reconcile: false)
        service.onMutation = { store.setEligible(false, reconcile: false) }
        await store.tick(force: true)
        XCTAssertEqual(service.operations.map(\.kind), [.start, .end])
        XCTAssertNil(store.visibleOpportunity)
    }

    func testUnknownWelcomeKeepsOriginalBytesAndUUID() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId), service: service, journal: journal)
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        service.offline = true
        await store.welcome(try XCTUnwrap(store.visibleOpportunity))
        let saved = try XCTUnwrap(journal.value)
        XCTAssertEqual(saved.kind, .welcome)
        XCTAssertNil(store.visibleOpportunity)
        service.offline = false
        await store.tick(force: true)
        let attempts = service.operations.filter { $0.kind == .welcome }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertEqual(saved.body, attempts[1].body)
        XCTAssertNil(journal.value)
        XCTAssertEqual(store.summary?.tokenBalance, "1")
    }

    func testPersistenceFailurePreventsSendingReward() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId), service: service, journal: journal)
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        journal.failSave = true
        await store.welcome(try XCTUnwrap(store.visibleOpportunity))
        XCTAssertFalse(service.operations.contains { $0.kind == .welcome })
        XCTAssertEqual(store.summary?.tokenBalance, "0")
    }

    func testCleanupFailureReplaysSameClaimWithoutAddingTokensLocally() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: service, journal: journal)
        service.current = f.stored; store.apply(f.stored); journal.failRemoval = true
        await store.claim()
        let saved = try XCTUnwrap(journal.value)
        XCTAssertEqual(saved.kind, .claim)
        XCTAssertEqual(store.summary?.tokenBalance, "3")
        journal.failRemoval = false
        await store.tick(force: true)
        let claims = service.operations.filter { $0.kind == .claim }
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0], claims[1])
        XCTAssertNil(journal.value)
        XCTAssertEqual(store.summary?.tokenBalance, "3")
    }

    func testLateDetachedAccountResponseRetainsJournalAndCannotUpdateUI() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId), service: service, journal: journal)
        store.setEligible(true, reconcile: false)
        service.onMutation = { store.deactivate() }
        await store.tick(force: true)
        XCTAssertNotNil(journal.value)
        XCTAssertEqual(store.summary?.tokenBalance, "0")
        XCTAssertNil(store.visibleOpportunity)
    }

    func testReceiptCannotOverwriteNewerWalletState() throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: service, journal: MemoryVisitorJournal())
        store.apply(f.claim.summary); store.apply(f.welcome.summary)
        XCTAssertEqual(store.summary?.tokenBalance, "3")
    }

    func testExpiryUsesUptimeAndOfflineCannotIssueVisitors() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        var time: TimeInterval = 100
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId), service: service,
                                       journal: MemoryVisitorJournal(), uptime: { time })
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        XCTAssertNotNil(store.visibleOpportunity)
        time += 200
        XCTAssertNil(store.visibleOpportunity)
        service.offline = true; await store.tick(force: true)
        XCTAssertNil(store.visibleOpportunity)
    }

    func testAnotherInstallationCannotPresentOrRenewSession() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); service.current = f.active
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: service, journal: MemoryVisitorJournal())
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        XCTAssertNil(store.visibleOpportunity)
        XCTAssertTrue(service.operations.isEmpty)
    }

    func testJournalIsPartitionedByServerAndAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = VisitorJournalStore(disk: AccountDiskStore(directory: directory))
        let user = UUID(); let id = UUID()
        let op = PendingVisitorOperation(id: id, kind: .claim, target: nil,
            body: try ActivityWire.encoder().encode(VisitorMutationBody(requestId: id, installationId: nil)))
        try journal.save(op, server: "https://a.invalid/", user: user)
        XCTAssertNil(try journal.load(server: "https://a.invalid/", user: UUID()))
        XCTAssertNil(try journal.load(server: "https://b.invalid/", user: user))
        XCTAssertEqual(try journal.load(server: "https://a.invalid/", user: user), op)
    }

    func testInvalidJournalPausesWithoutDeletingIt() throws {
        let f = try VisitorContract.load(); let journal = MemoryVisitorJournal()
        journal.value = PendingVisitorOperation(id: UUID(), kind: .welcome, target: nil, body: Data())
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: FakeVisitors(f), journal: journal)
        XCTAssertTrue(store.recoveryLocked)
        XCTAssertNotNil(journal.value)
    }
}
