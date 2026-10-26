import XCTest
import Foundation
import SwiftUI
import UIKit
import RealityKit
import Combine
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
    var state = VisitorJournalState()
    var value: PendingVisitorOperation? {
        get { state.pending }
        set { state.pending = newValue }
    }
    var failSave = false
    var failRemoval = false
    func load(server: String, user: UUID) throws -> VisitorJournalState? { state }
    func save(_ value: VisitorJournalState, server: String, user: UUID) throws {
        if failSave || (value.pending == nil && failRemoval) { throw URLError(.cannotWriteToFile) }
        self.state = value
    }
}

@MainActor
private final class FakeVisitors: VisitorServing {
    let serverID = "https://visitor-test.invalid/"
    let contract: VisitorContract
    var current: APIVisitorSummary
    var operations: [PendingVisitorOperation] = []
    var offline = false
    var blockHeartbeat = false
    var heartbeatContinuation: CheckedContinuation<Void, Never>?
    var onMutation: (() -> Void)?
    var nextMutationError: Error?
    init(_ contract: VisitorContract) { self.contract = contract; current = contract.initial }
    func read() async throws -> APIVisitorSummary {
        if offline { throw URLError(.notConnectedToInternet) }
        return current
    }
    func mutate(_ operation: PendingVisitorOperation) async throws -> (APIVisitorSummary, APIVisitorReward?) {
        try operation.validate(); operations.append(operation); onMutation?()
        if operation.kind == .heartbeat && blockHeartbeat {
            await withCheckedContinuation { heartbeatContinuation = $0 }
        }
        if let error = nextMutationError { nextMutationError = nil; throw error }
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
    func testTimedOutAssetReleasesSharedImportAndRendererCanRetryWithoutAppSwitch() async throws {
        let subject = PassthroughSubject<Entity, Error>()
        var attempts = 0, cancelled = false
        let recovered = Entity(); recovered.name = "recovered-butterfly"
        let library = VisitorModelLibrary(importer: {
            attempts += 1
            let request = VisitorAssetLoadRequest()
            if attempts == 1 {
                return try await request.run(timeoutSeconds: 0.03) {
                    subject.handleEvents(receiveCancel: { cancelled = true }).eraseToAnyPublisher()
                }
            }
            return try await request.run { Just(recovered).setFailureType(to: Error.self).eraseToAnyPublisher() }
        })
        let fixture = try VisitorContract.load()
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: FakeVisitors(fixture), journal: MemoryVisitorJournal())
        let renderer = RealityGardenRenderer(visitorModels: library)
        defer { renderer.stop() }
        renderer.setVisitors(store)
        try await waitUntil { renderer.visitorAssetIssue != nil }
        XCTAssertTrue(renderer.visitorAssetIssue?.contains("timed out") == true)
        XCTAssertFalse(renderer.visitorAssetReady)
        XCTAssertTrue(cancelled)
        XCTAssertNil(library.cachedClone())
        renderer.setVisitors(store)
        try await waitUntil { renderer.visitorAssetReady }
        XCTAssertNil(renderer.visitorAssetIssue)
        XCTAssertEqual(library.loadCount, 2)
        subject.send(Entity()); subject.send(completion: .finished)
        await Task.yield()
        XCTAssertEqual(library.cachedClone()?.name, "recovered-butterfly")
        XCTAssertEqual(library.loadCount, 2)
    }

    func testVisitorTimeoutRecoveryClearsStaleMessageAndReplaysOriginalRequest() async throws {
        let fixture = try VisitorContract.load(), journal = MemoryVisitorJournal()
        let service = FakeVisitors(fixture)
        service.nextMutationError = URLError(.timedOut)
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(fixture.active.session?.installationId),
                                       service: service, journal: journal)
        store.setEligible(true, reconcile: false)
        await store.tick(force: true)
        XCTAssertFalse(store.connected)
        XCTAssertTrue(store.message?.hasPrefix("Visitors paused.") == true)
        let original = try XCTUnwrap(journal.value)
        await store.tick(force: true)
        XCTAssertTrue(store.connected)
        XCTAssertNil(store.message)
        XCTAssertNil(journal.value)
        XCTAssertEqual(service.operations[0].id, original.id)
        XCTAssertEqual(service.operations[1].id, original.id)
        XCTAssertEqual(service.operations[1].body, original.body)
    }

    func testPreloadCachesBeforeRendererExistsAndWarmAttachmentDoesNotWaitForAnotherTask() async throws {
        var importGate: CheckedContinuation<Entity, Error>?
        defer { importGate?.resume(returning: Entity()) }
        let library = VisitorModelLibrary(importer: {
            try await withCheckedThrowingContinuation { importGate = $0 }
        })
        library.preload(); library.preload()
        XCTAssertEqual(library.loadCount, 1)
        try await waitUntil { importGate != nil }
        XCTAssertNil(library.cachedClone())
        let pending = try XCTUnwrap(importGate)
        pending.resume(returning: Entity()); importGate = nil
        try await waitUntil { library.cachedClone() != nil }

        let fixture = try VisitorContract.load()
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: FakeVisitors(fixture), journal: MemoryVisitorJournal())
        let renderer = RealityGardenRenderer(visitorModels: library)
        defer { renderer.stop() }
        renderer.setVisitors(store)
        // Readiness must be synchronous when startup has already warmed the asset.
        XCTAssertTrue(renderer.visitorAssetReady)
        XCTAssertEqual(library.loadCount, 1)
        renderer.detachView(); renderer.setVisitors(store)
        XCTAssertTrue(renderer.visitorAssetReady)
    }

    #if DEBUG
    func testOverlayChangesFromLoadingToModelWithoutSceneOrLayoutChange() async throws {
        let fixture = try VisitorContract.load()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(fixture.active.session?.installationId),
                                       service: FakeVisitors(fixture), journal: MemoryVisitorJournal())
        store.apply(fixture.active); store.setEligible(true, reconcile: false)
        XCTAssertFalse(store.visibleOpportunities.isEmpty)
        var importGate: CheckedContinuation<Entity, Error>?
        let library = VisitorModelLibrary(importer: {
            try await withCheckedThrowingContinuation { importGate = $0 }
        })
        let renderer = RealityGardenRenderer(visitorModels: library)
        renderer.setVisitors(store)
        var states: [VisitorArtworkState] = []
        VisitorVisualDiagnostics.onArtwork = { _, state in states.append(state) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VisitorGardenOverlay(store: store, renderer: renderer))
        window.makeKeyAndVisible()
        defer {
            importGate?.resume(returning: Entity())
            window.isHidden = true; window.rootViewController = nil
            VisitorVisualDiagnostics.onArtwork = nil; renderer.stop()
        }
        try await waitUntil { importGate != nil && states.contains(.loading) }
        XCTAssertFalse(states.contains(where: { $0.usesFallback }))
        let frame = window.frame
        let pending = try XCTUnwrap(importGate)
        pending.resume(returning: Entity()); importGate = nil
        try await waitUntil { states.contains(.model) }
        XCTAssertTrue(renderer.visitorAssetReady)
        XCTAssertEqual(window.frame, frame)
        XCTAssertFalse(states.contains(where: { $0.usesFallback }))
        XCTAssertEqual(library.loadCount, 1)
    }
    #endif

    func testLoadedButterflySurvivesPausesAndRendererReplacementWithoutAnotherImport() async throws {
        let fixture = try VisitorContract.load()
        let service = FakeVisitors(fixture)
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: service, journal: MemoryVisitorJournal())
        let renderer = RealityGardenRenderer()
        defer { renderer.stop() }
        renderer.setVisitors(store)
        for _ in 0..<1500 {
            if renderer.visitorAssetReady || renderer.visitorAssetIssue != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(renderer.visitorAssetReady, renderer.visitorAssetIssue ?? "Butterfly did not load")
        let imports = VisitorModelLibrary.shared.loadCount
        for _ in 0..<20 {
            renderer.setActive(false); renderer.detachView()
            renderer.setVisitors(store); renderer.setActive(true)
            XCTAssertTrue(renderer.visitorAssetReady)
        }
        renderer.stop()
        let replacement = RealityGardenRenderer()
        defer { replacement.stop() }
        replacement.setVisitors(store)
        try await waitUntil { replacement.visitorAssetReady }
        XCTAssertEqual(VisitorModelLibrary.shared.loadCount, imports)
        XCTAssertTrue(service.operations.isEmpty)
        XCTAssertEqual(store.tokenBalance, "0")
        XCTAssertEqual(fixture.initial.tokenBalance, "0")
    }

    func testScheduledVisitorsStayHiddenUntilDueAndAllowWelcomingAnyVisibleCopy() async throws {
        let f = try VisitorContract.load(), service = FakeVisitors(try VisitorContract.load())
        let session = try XCTUnwrap(f.active.session)
        let now = f.active.serverTime
        let first = APIVisitorOpportunity(opportunityId: UUID(), sessionId: session.sessionId,
            issuedAt: now.addingTimeInterval(5), expiresAt: now.addingTimeInterval(25),
            visualKey: "forest-butterfly-v1", tokens: "1", lane: 1)
        let second = APIVisitorOpportunity(opportunityId: UUID(), sessionId: session.sessionId,
            issuedAt: now.addingTimeInterval(6), expiresAt: now.addingTimeInterval(26),
            visualKey: "forest-butterfly-v1", tokens: "1", lane: 2)
        let array = try JSONSerialization.jsonObject(with: ActivityWire.encoder().encode([first, second]))
        let summary = try changed(f.active, ["opportunities": array, "arrivalProtocol": 2])
        var elapsed: TimeInterval = 0
        let store = VisitorCoordinator(userID: UUID(), installationID: session.installationId,
                                      service: service, journal: MemoryVisitorJournal(), uptime: { elapsed })
        store.apply(summary); store.setEligible(true, reconcile: false)
        XCTAssertTrue(store.visibleOpportunities.isEmpty)
        await store.welcome(first)
        XCTAssertTrue(service.operations.isEmpty)
        elapsed = 5
        XCTAssertEqual(store.visibleOpportunities.map(\.id), [first.id])
        elapsed = 6
        XCTAssertEqual(Set(store.visibleOpportunities.map(\.id)), Set([first.id, second.id]))
        await store.welcome(second)
        XCTAssertEqual(service.operations.last?.target, second.id)
        store.apply(try changed(summary, ["version": summary.version + 100]))
        elapsed = 26
        XCTAssertTrue(store.visibleOpportunities.isEmpty)
    }

    func testNewArrivalProtocolIsNegotiatedOnlyWhenAdvertised() async throws {
        let f = try VisitorContract.load(), service = FakeVisitors(try VisitorContract.load())
        service.current = try changed(f.initial, ["arrivalProtocol": 2])
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: service,
                                      journal: MemoryVisitorJournal())
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        let operation = try XCTUnwrap(service.operations.first)
        XCTAssertEqual(operation.kind, .start)
        let body = try ActivityWire.decoder().decode(VisitorMutationBody.self, from: operation.body)
        XCTAssertEqual(body.arrivalProtocol, 2)
    }

    func testScheduledReducedMotionLanesAreDistinctAndLegacyPoseIsPreserved() {
        let poses = (1...12).map { VisitorFlightPose(elapsed: 0, remaining: 20, reduceMotion: true, lane: $0) }
        XCTAssertEqual(Set(poses.map { "\($0.x),\($0.y)" }).count, 12)
        XCTAssertTrue(poses.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        let legacy = VisitorFlightPose(elapsed: 0, remaining: 20, reduceMotion: true)
        XCTAssertEqual(legacy.x, 0.5); XCTAssertEqual(legacy.y, 0.36)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Visitor test did not reach the expected state")
        throw URLError(.timedOut)
    }

    private func releaseHeartbeat(_ service: FakeVisitors) {
        service.blockHeartbeat = false
        service.heartbeatContinuation?.resume(); service.heartbeatContinuation = nil
    }

    func testHeartbeatKeepsVisitorVisibleAndQueuesOneDurableTap() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: journal)
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        let visitor = try XCTUnwrap(store.visibleOpportunity)
        service.blockHeartbeat = true
        defer { releaseHeartbeat(service) }
        let heartbeat = Task { await store.tick(force: true) }
        try await waitUntil { service.heartbeatContinuation != nil }
        XCTAssertEqual(store.visibleOpportunity?.id, visitor.id)
        XCTAssertTrue(store.canRequestReward)
        XCTAssertFalse(store.recoveringRequest)
        await store.welcome(visitor)
        let saved = try XCTUnwrap(journal.state.queuedReward)
        XCTAssertEqual(journal.value?.kind, .heartbeat)
        XCTAssertEqual(saved.kind, .welcome)
        XCTAssertNil(store.visibleOpportunity)
        await store.welcome(visitor) // A second tap cannot overwrite the first.
        XCTAssertEqual(journal.state.queuedReward, saved)
        XCTAssertFalse(service.operations.contains { $0.kind == .welcome })
        releaseHeartbeat(service); await heartbeat.value
        XCTAssertEqual(service.operations.map(\.kind), [.start, .heartbeat, .welcome])
        XCTAssertEqual(service.operations.last, saved)
        XCTAssertNil(journal.state.pending); XCTAssertNil(journal.state.queuedReward)
        XCTAssertEqual(store.summary?.tokenBalance, "1")
    }

    func testQueuedTapSurvivesLostHeartbeatAndRelaunch() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let user = UUID(), installation = try XCTUnwrap(f.active.session?.installationId)
        let store = VisitorCoordinator(userID: user, installationID: installation, service: service, journal: journal)
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        let visitor = try XCTUnwrap(store.visibleOpportunity)
        service.blockHeartbeat = true
        defer { releaseHeartbeat(service) }
        let task = Task { await store.tick(force: true) }
        try await waitUntil { service.heartbeatContinuation != nil }
        await store.welcome(visitor)
        let saved = journal.state
        service.offline = true; releaseHeartbeat(service); await task.value
        XCTAssertEqual(journal.state, saved)
        store.deactivate()
        service.offline = false
        let relaunched = VisitorCoordinator(userID: user, installationID: installation, service: service, journal: journal)
        await relaunched.tick(force: true)
        let heartbeats = service.operations.filter { $0.kind == .heartbeat }
        XCTAssertEqual(heartbeats.count, 2); XCTAssertEqual(heartbeats[0], heartbeats[1])
        XCTAssertEqual(service.operations.first { $0.kind == .welcome }, saved.queuedReward)
        XCTAssertEqual(relaunched.summary?.tokenBalance, "1")
        XCTAssertNil(journal.value)
    }

    func testQueueSaveFailureLeavesVisitorAvailableAndSendsNoReward() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: journal)
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        let visitor = try XCTUnwrap(store.visibleOpportunity)
        service.blockHeartbeat = true
        defer { releaseHeartbeat(service) }
        let task = Task { await store.tick(force: true) }
        try await waitUntil { service.heartbeatContinuation != nil }
        journal.failSave = true; await store.welcome(visitor)
        XCTAssertEqual(store.visibleOpportunity?.id, visitor.id)
        XCTAssertNil(journal.state.queuedReward)
        journal.failSave = false; releaseHeartbeat(service); await task.value
        XCTAssertFalse(service.operations.contains { $0.kind == .welcome })
    }

    func testHeartbeatDoesNotRewindClockOrExtendExpiry() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        var time: TimeInterval = 100
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: MemoryVisitorJournal(), uptime: { time })
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        let visitor = try XCTUnwrap(store.visibleOpportunity)
        time += 5
        let before = try XCTUnwrap(store.serverNow)
        store.apply(f.active) // Idempotent receipt with its original timestamp.
        XCTAssertEqual(store.serverNow, before)
        time += visitor.expiresAt.timeIntervalSince(before)
        XCTAssertNil(store.visibleOpportunity)
        await store.welcome(visitor)
        XCTAssertFalse(service.operations.contains { $0.kind == .welcome })
    }

    func testStoredClaimCanQueueBehindHeartbeatWithoutDuplicateTap() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        service.current = try changed(f.active, ["claimableVisits": "2", "storedVisitsMicroUnits": "2500000"])
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: journal)
        store.setEligible(true, reconcile: false)
        service.blockHeartbeat = true
        defer { releaseHeartbeat(service) }
        let task = Task { await store.tick(force: true) }
        try await waitUntil { service.heartbeatContinuation != nil }
        await store.claim()
        let saved = try XCTUnwrap(journal.state.queuedReward)
        XCTAssertEqual(saved.kind, .claim)
        await store.claim()
        XCTAssertEqual(journal.state.queuedReward, saved)
        releaseHeartbeat(service); await task.value
        XCTAssertEqual(service.operations.map(\.kind), [.heartbeat, .claim])
        XCTAssertEqual(service.operations.last, saved)
        XCTAssertEqual(store.summary?.tokenBalance, "3")
    }

    func testQueuedRewardRemainsScopedWhenAccountDetachesDuringHeartbeat() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f); let journal = MemoryVisitorJournal()
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: journal)
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        let visitor = try XCTUnwrap(store.visibleOpportunity)
        service.blockHeartbeat = true
        defer { releaseHeartbeat(service) }
        let task = Task { await store.tick(force: true) }
        try await waitUntil { service.heartbeatContinuation != nil }
        await store.welcome(visitor)
        let saved = journal.state
        store.deactivate(); releaseHeartbeat(service); await task.value
        XCTAssertEqual(journal.state, saved)
        XCTAssertEqual(store.summary?.tokenBalance, "0")
        XCTAssertFalse(service.operations.contains { $0.kind == .welcome })
        XCTAssertNil(store.visibleOpportunity)
    }

    func testLegacyJournalLoadsAndQueuedStateRoundTripsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AccountDiskStore(directory: directory), user = UUID(), id = UUID()
        let legacy = PendingVisitorOperation(id: id, kind: .heartbeat, target: UUID(),
            body: try ActivityWire.encoder().encode(VisitorMutationBody(requestId: id, installationId: UUID())))
        try disk.save(legacy, kind: "visitor-request", server: "test", user: user)
        let journal = VisitorJournalStore(disk: disk)
        XCTAssertEqual(try journal.load(server: "test", user: user)?.pending, legacy)
        let rewardID = UUID()
        let reward = PendingVisitorOperation(id: rewardID, kind: .welcome, target: UUID(),
            body: try ActivityWire.encoder().encode(VisitorMutationBody(requestId: rewardID, installationId: nil)))
        let state = VisitorJournalState(pending: legacy, queuedReward: reward)
        try journal.save(state, server: "test", user: user)
        XCTAssertEqual(try journal.load(server: "test", user: user), state)
        XCTAssertThrowsError(try VisitorJournalState(pending: reward, queuedReward: reward).validate())
    }

    #if DEBUG
    func testRenderedFlightContinuesForFiveSecondHeartbeatWithoutNetworkFrames() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: MemoryVisitorJournal())
        store.setEligible(true, reconcile: false); await store.tick(force: true)
        var frames: [VisitorFlightPose] = []
        VisitorVisualDiagnostics.onFrame = { _, pose in frames.append(pose) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VisitorGardenOverlay(store: store, reduceMotionOverride: false))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; VisitorVisualDiagnostics.onFrame = nil; releaseHeartbeat(service) }
        try await waitUntil { !frames.isEmpty }
        service.blockHeartbeat = true
        let task = Task { await store.tick(force: true) }
        try await waitUntil { service.heartbeatContinuation != nil }
        let requestCount = service.operations.count
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertGreaterThan(frames.count, 15)
        XCTAssertGreaterThan((frames.map(\.x).max() ?? 0) - (frames.map(\.x).min() ?? 0), 0.15)
        XCTAssertGreaterThan((frames.map(\.flap).max() ?? 0) - (frames.map(\.flap).min() ?? 0), 0.5)
        let afterThreeSeconds = frames.count
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(frames.count, afterThreeSeconds + 5)
        XCTAssertEqual(service.operations.count, requestCount)
        XCTAssertNotNil(store.visibleOpportunity)
        releaseHeartbeat(service); await task.value
        let countAtResponse = frames.count
        try await waitUntil { frames.count > countAtResponse }
        XCTAssertGreaterThan(try XCTUnwrap(frames.last).x, 0.3, "Heartbeat restarted the entry animation")
    }

    func testRenderedReduceMotionIsStaticButExpiresWithoutPolling() async throws {
        let f = try VisitorContract.load(); let service = FakeVisitors(f)
        var time: TimeInterval = 0
        let store = VisitorCoordinator(userID: UUID(), installationID: try XCTUnwrap(f.active.session?.installationId),
                                       service: service, journal: MemoryVisitorJournal(), uptime: { time })
        store.apply(f.active); store.setEligible(true, reconcile: false)
        var frames: [VisitorFlightPose] = []
        var rendered = false
        VisitorVisualDiagnostics.onFrame = { _, pose in frames.append(pose) }
        VisitorVisualDiagnostics.onVisibility = { _, visible in rendered = visible }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VisitorGardenOverlay(store: store, reduceMotionOverride: true))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            VisitorVisualDiagnostics.onFrame = nil; VisitorVisualDiagnostics.onVisibility = nil
        }
        try await waitUntil { rendered && !frames.isEmpty }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(frames.allSatisfy { $0 == VisitorFlightPose(elapsed: 0, remaining: 60, reduceMotion: true) })
        time += 200
        XCTAssertNil(store.visibleOpportunity)
        try await waitUntil { !rendered }
        XCTAssertTrue(service.operations.isEmpty)
    }
    #endif

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
        try journal.save(VisitorJournalState(pending: op), server: "https://a.invalid/", user: user)
        XCTAssertNil(try journal.load(server: "https://a.invalid/", user: UUID()))
        XCTAssertNil(try journal.load(server: "https://b.invalid/", user: user))
        XCTAssertEqual(try journal.load(server: "https://a.invalid/", user: user)?.pending, op)
    }

    func testInvalidJournalPausesWithoutDeletingIt() throws {
        let f = try VisitorContract.load(); let journal = MemoryVisitorJournal()
        journal.value = PendingVisitorOperation(id: UUID(), kind: .welcome, target: nil, body: Data())
        let store = VisitorCoordinator(userID: UUID(), installationID: UUID(), service: FakeVisitors(f), journal: journal)
        XCTAssertTrue(store.recoveryLocked)
        XCTAssertNotNil(journal.value)
    }
}
