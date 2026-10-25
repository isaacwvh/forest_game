import XCTest
import Foundation
@testable import MovementForest

private struct ActivityContract: Decodable {
    let profile: APIProfile
    let catalogue: APICatalogue
    let gardenBeforeSync: APIGarden
    let enrolment: APIActivityEnrolment
    let syncRequest: ActivitySyncRequest
    let syncResult: APIActivitySyncResult
    let status: APIActivityStatus
    let recaps: APIRewardRecaps
    let acknowledgement: APIRecapAcknowledgement
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "activity-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@MainActor
private final class MemoryActivityJournal: ActivityJournalPersisting {
    var value: ActivityJournalState?
    var failSave = false
    var failLoad = false
    var failRemoval = false
    func load(server: String, user: UUID) throws -> ActivityJournalState? {
        if failLoad { throw URLError(.cannotDecodeContentData) }
        return value
    }
    func save(_ state: ActivityJournalState, server: String, user: UUID) throws {
        if failSave || (failRemoval && state.operations.count < (value?.operations.count ?? 0)) {
            throw URLError(.cannotWriteToFile)
        }
        value = state
    }
}

@MainActor
private final class SyncHealthProvider: HealthDataProviding {
    let isAvailable = true
    let isFixture = false // An in-memory test double, never exposed in the app.
    let fixture: ActivityContract
    var amount: Double? = 3000
    var reads = 0
    init(_ fixture: ActivityContract) { self.fixture = fixture }
    func requestReadAccess() async throws { }
    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport {
        reads += 1
        let instant = fixture.syncRequest.observedAt
        let days = ActivityCalendar.days(endingAt: instant, count: 7, timeZone: timeZone)
            .map { ActivityDay(start: $0.start, end: $0.end, steps: amount) }
        return ActivityReport(observedAt: instant, timeZoneIdentifier: timeZone.identifier, days: days,
                              workouts: [], stepsIssue: nil, workoutsIssue: nil, isFixture: false)
    }
}

@MainActor
private final class SyncTestService: GardenServing, ActivityServing {
    let serverID = "https://f5.test"
    let fixture: ActivityContract
    var current: APIGarden
    var statusValue: APIActivityStatus
    var syncBodies: [Data] = []
    var enrolBodies: [Data] = []
    var ackBodies: [Data] = []
    var receipts: [UUID: APIActivitySyncResult] = [:]
    var pendingRecaps: [APIRewardRecap] = []
    var offline = false
    var loseNextResponse = false
    var syncError: APIError?
    var pauseNext = false
    var gate: CheckedContinuation<Void, Never>?

    init(_ fixture: ActivityContract) {
        self.fixture = fixture; current = fixture.gardenBeforeSync; statusValue = fixture.status
    }
    func profile() async throws -> APIProfile { fixture.profile }
    func catalogue() async throws -> APICatalogue {
        if offline { throw URLError(.notConnectedToInternet) }
        return fixture.catalogue
    }
    func garden() async throws -> APIGarden {
        if offline { throw URLError(.notConnectedToInternet) }
        return current
    }
    func inventory(after: UUID?) async throws -> APIInventory { APIInventory(plants: [], nextCursor: nil) }
    func edit(body: Data) async throws -> GardenEditResult { throw URLError(.unsupportedURL) }
    func activityStatus() async throws -> APIActivityStatus {
        if offline { throw URLError(.notConnectedToInternet) }
        return statusValue
    }
    func setDevice(_ device: APIActivityDevice?) {
        let old = statusValue
        statusValue = APIActivityStatus(serverTime: old.serverTime, gameTimezone: old.gameTimezone,
                                        supportedMetrics: old.supportedMetrics, reconciliationDays: old.reconciliationDays,
                                        queuedUploadMaxAgeDays: old.queuedUploadMaxAgeDays, device: device,
                                        activitySteps: old.activitySteps, firstMaturityCount: old.firstMaturityCount, lastSyncAt: old.lastSyncAt)
    }
    func enrol(body: Data) async throws -> APIActivityEnrolment {
        enrolBodies.append(body)
        let request = try ActivityWire.decoder().decode(ActivityEnrolmentRequest.self, from: body)
        let template = fixture.enrolment.device
        let device = APIActivityDevice(deviceId: UUID(), installationId: request.installationId, enrolledAt: request.observedAt,
                                       baselineDate: request.steps == nil ? nil : template.baselineDate,
                                       baselineObservedAt: request.steps == nil ? nil : request.observedAt,
                                       baselineSteps: request.steps, ready: request.steps != nil)
        setDevice(device)
        return APIActivityEnrolment(requestId: request.requestId, device: device)
    }
    func sync(body: Data) async throws -> APIActivitySyncResult {
        syncBodies.append(body)
        if pauseNext { pauseNext = false; await withCheckedContinuation { gate = $0 } }
        if offline { throw URLError(.notConnectedToInternet) }
        if let error = syncError { syncError = nil; throw error }
        let request = try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: body)
        if let receipt = receipts[request.requestId] { return receipt }
        let template = fixture.syncResult
        let result = APIActivitySyncResult(requestId: request.requestId, acceptedAt: template.acceptedAt,
                                           device: template.device, days: template.days, garden: template.garden,
                                           activitySteps: template.activitySteps, firstMaturityCount: template.firstMaturityCount,
                                           recapId: template.recapId)
        receipts[request.requestId] = result; current = result.garden
        pendingRecaps = fixture.recaps.recaps
        if loseNextResponse { loseNextResponse = false; throw URLError(.networkConnectionLost) }
        return result
    }
    func recaps(after: UUID?) async throws -> APIRewardRecaps {
        APIRewardRecaps(recaps: after == nil ? pendingRecaps : [], nextCursor: nil)
    }
    func acknowledge(recap: UUID, body: Data) async throws -> APIRecapAcknowledgement {
        ackBodies.append(body)
        let identity = try JSONDecoder().decode(RequestIdentity.self, from: body)
        pendingRecaps.removeAll { $0.id == recap }
        return APIRecapAcknowledgement(requestId: identity.requestId, recapId: recap, acknowledgedAt: fixture.status.serverTime)
    }
}

@MainActor
final class ActivitySyncTests: XCTestCase {
    func testDismissedLoadingEntryDoesNotReopenWhenSyncFinishes() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        service.pauseNext = true
        let entry = AppEntryRecapCoordinator()
        entry.begin(sync: sync, editor: editor)
        XCTAssertTrue(entry.showing)
        for _ in 0..<300 {
            if service.gate != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let gate = try XCTUnwrap(service.gate)
        entry.showing = false; entry.dismissed()
        gate.resume(); service.gate = nil
        for _ in 0..<300 {
            if !sync.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(entry.showing)
        entry.begin(sync: sync, editor: editor)
        XCTAssertFalse(entry.showing, "An ordinary in-session update must not rearm entry presentation")
        entry.background()
        entry.begin(sync: sync, editor: editor)
        XCTAssertTrue(entry.showing)
        entry.background()
    }

    func testRecapDismissalIsPersistedWhileAnotherSyncIsInFlight() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        let shown = try XCTUnwrap(sync.recaps.first)
        service.pauseNext = true
        let running = Task { await sync.synchronize() }
        for _ in 0..<300 {
            if service.gate != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let gate = try XCTUnwrap(service.gate)
        await sync.dismissRecaps(ids: [shown.id])
        XCTAssertTrue(journal.value?.dismissedRecaps.contains(shown.id) == true)
        XCTAssertTrue(journal.value?.operations.contains { $0.recapID == shown.id } == true)
        gate.resume(); service.gate = nil
        _ = await running.value
        XCTAssertEqual(service.ackBodies.count, 1)
        XCTAssertTrue(sync.recaps.isEmpty)
    }

    func testRecapDismissalAcknowledgesOnlyThePresentedBatch() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        let shown = try XCTUnwrap(sync.recaps.first)
        let later = APIRewardRecap(recapId: UUID(), createdAt: shown.createdAt.addingTimeInterval(1), payload: shown.payload)
        service.pendingRecaps = [shown, later]
        // A normal foreground sync discovers another receipt after the UI took its snapshot.
        await sync.setEnabled(false)
        _ = await sync.synchronize()
        await sync.dismissRecaps(ids: [shown.id])
        XCTAssertEqual(sync.recaps.map(\.id), [later.id])
        XCTAssertEqual(service.ackBodies.count, 1)
        XCTAssertEqual(service.current.plants.first?.growthMicroUnits, service.fixture.syncResult.garden.plants.first?.growthMicroUnits)
    }

    private func health(_ fixture: ActivityContract) -> ActivityStore {
        ActivityStore(provider: SyncHealthProvider(fixture), defaults: UserDefaults(suiteName: "f5-" + UUID().uuidString)!)
    }
    private func editor(_ service: SyncTestService, disk: AccountDiskStore? = nil) throws -> GardenEditorStore {
        GardenEditorStore(profile: service.fixture.profile, service: service, assets: try BundleAssetCatalog(), cache: disk)
    }
    private func coordinator(_ service: SyncTestService, editor: GardenEditorStore, health: ActivityStore,
                             journal: MemoryActivityJournal) -> ActivitySyncCoordinator {
        ActivitySyncCoordinator(editor: editor, health: health, service: service,
                                installationID: service.fixture.syncRequest.installationId, journal: journal)
    }

    func testActualBackendContractPreservesGrowthTransformsAndRecap() throws {
        let fixture = try ActivityContract.load()
        XCTAssertEqual(fixture.syncResult.garden.layoutVersion, fixture.gardenBeforeSync.layoutVersion)
        XCTAssertGreaterThan(fixture.syncResult.garden.stateVersion, fixture.gardenBeforeSync.stateVersion)
        XCTAssertEqual(fixture.syncResult.garden.plants.first?.placement, fixture.gardenBeforeSync.plants.first?.placement)
        XCTAssertEqual(fixture.syncResult.garden.plants.first?.growthMicroUnits, "10000000")
        XCTAssertEqual(fixture.recaps.recaps.first?.payload.plants.first?.awardedGrowthMicroUnits, "10000000")
        XCTAssertEqual(fixture.syncResult.garden.plants.first?.growthProgress?.nextStageMicroUnits, "100000000")
    }

    func testNullStepsEncodeExplicitlyAndInvalidQuantitiesFail() throws {
        let data = try ActivityWire.encoder().encode(ActivityDayUpload(gameDate: "2026-10-22", steps: nil))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"steps\":null"))
        let whole = try ActivityWire.encoder().encode(ActivityDayUpload(gameDate: "2026-10-22", steps: 123))
        XCTAssertTrue(String(decoding: whole, as: UTF8.self).contains("\"steps\":123"))
        XCTAssertEqual(try ActivityWire.steps(123), 123)
        XCTAssertNil(try ActivityWire.steps(nil))
        for value in [Double.nan, .infinity, -.infinity, -1, -0.1, 1_000_000_001,
                      1_000_000_000.1, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try ActivityWire.steps(value))
        }
    }

    func testFractionalHealthTotalsUseWholeCumulativeSteps() throws {
        let cases: [(Double, Int64)] = [
            (0, 0), (0.9, 0), (1.5, 1), (123.999999999, 123),
            (3000.75, 3000), (999_999_999.9, 999_999_999), (1_000_000_000, 1_000_000_000)
        ]
        for (healthTotal, expected) in cases {
            XCTAssertEqual(try ActivityWire.steps(healthTotal), expected)
        }
        let reads: [Double] = [1000.2, 1000.9, 1001.1]
        XCTAssertEqual(try reads.map { try XCTUnwrap(ActivityWire.steps($0)) }, [1000, 1000, 1001])
    }

    func testFractionalObservationEnrolsAndSyncsAsWholeCounts() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        service.setDevice(nil)
        let editor = try editor(service), health = health(service.fixture)
        let provider = try XCTUnwrap(health.provider as? SyncHealthProvider)
        provider.amount = 3000.75
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        let enrolment = try ActivityWire.decoder().decode(ActivityEnrolmentRequest.self, from: XCTUnwrap(service.enrolBodies.first))
        XCTAssertEqual(enrolment.steps, 3000)
        XCTAssertTrue(service.syncBodies.isEmpty)
        provider.amount = 3001.9
        _ = await sync.synchronize()
        let upload = try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: XCTUnwrap(service.syncBodies.first))
        XCTAssertTrue(upload.days.allSatisfy { $0.steps == 3001 })
        XCTAssertEqual(sync.pendingCount, 0)
    }

    func testNoUploadOrHealthReadBeforeSeparateOptIn() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        _ = await sync.synchronize()
        XCTAssertTrue(service.syncBodies.isEmpty); XCTAssertTrue(service.enrolBodies.isEmpty)
        XCTAssertEqual((health.provider as? SyncHealthProvider)?.reads, 0)
        XCTAssertFalse(sync.enabled)
    }

    func testInitialEnrolmentOnlyEstablishesBaseline() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        service.setDevice(nil)
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertEqual(service.enrolBodies.count, 1); XCTAssertTrue(service.syncBodies.isEmpty)
        XCTAssertEqual(sync.status?.device?.baselineSteps, 3000)
        XCTAssertEqual(editor.confirmed?.plants.first?.growthMicroUnits, "0")
    }

    func testUnavailableEnrolmentDoesNotEstablishZeroBaseline() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        service.setDevice(nil)
        let editor = try editor(service), health = health(service.fixture)
        (health.provider as? SyncHealthProvider)?.amount = nil
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertNil(sync.status?.device?.baselineSteps)
        XCTAssertEqual(sync.status?.device?.ready, false)
        XCTAssertTrue(service.syncBodies.isEmpty)
    }

    func testLostResponseRelaunchRetriesIdenticalBytes() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let first = try editor(service), health = health(service.fixture)
        await first.start(); service.loseNextResponse = true
        let sync = coordinator(service, editor: first, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertEqual(sync.pendingCount, 1); XCTAssertFalse(first.canEdit)
        let restoredEditor = try editor(service); await restoredEditor.start()
        let restored = coordinator(service, editor: restoredEditor, health: health, journal: journal)
        _ = await restored.synchronize()
        XCTAssertGreaterThanOrEqual(service.syncBodies.count, 2)
        XCTAssertEqual(service.syncBodies[0], service.syncBodies[1])
        XCTAssertEqual(restored.pendingCount, 0)
        XCTAssertEqual(restoredEditor.confirmed?.plants.first?.growthMicroUnits, "10000000")
    }

    func testFractionalReadDoesNotRewriteSavedRetryBytes() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let first = try editor(service), health = health(service.fixture)
        let provider = try XCTUnwrap(health.provider as? SyncHealthProvider)
        provider.amount = 3000.75
        await first.start(); service.loseNextResponse = true
        let sync = coordinator(service, editor: first, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertEqual(sync.pendingCount, 1)
        let original = try XCTUnwrap(service.syncBodies.first)
        let queued = try XCTUnwrap(journal.value?.operations.first)
        XCTAssertEqual(queued.body, original)
        let request = try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: original)
        XCTAssertTrue(request.days.allSatisfy { $0.steps == 3000 })
        provider.amount = 3001.9
        let restoredEditor = try editor(service); await restoredEditor.start()
        let restored = coordinator(service, editor: restoredEditor, health: health, journal: journal)
        _ = await restored.synchronize()
        XCTAssertGreaterThanOrEqual(service.syncBodies.count, 3)
        XCTAssertEqual(service.syncBodies[1], original)
        let latest = try XCTUnwrap(service.syncBodies.last)
        XCTAssertEqual(try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: latest).days.last?.steps, 3001)
        XCTAssertEqual(restored.pendingCount, 0)
    }

    func testFailedJournalWritePreventsTransmission() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start(); journal.failSave = true
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertTrue(service.syncBodies.isEmpty); XCTAssertTrue(service.enrolBodies.isEmpty)
    }

    func testCorruptJournalBlocksEditingAndUploads() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start(); journal.failLoad = true
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        XCTAssertTrue(sync.recoveryLocked); XCTAssertFalse(editor.canEdit)
        _ = await sync.synchronize(); XCTAssertTrue(service.syncBodies.isEmpty)
    }

    func testExpiredTokenPreservesPendingRequest() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        service.syncError = APIError(status: 401, code: "invalid_token", message: "Expired")
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertEqual(sync.pendingCount, 1)
        _ = await sync.synchronize()
        XCTAssertEqual(service.syncBodies[0], service.syncBodies[1])
        XCTAssertEqual(sync.pendingCount, 0)
    }

    func testIdempotencyConflictRetainsQueueAndLocksRecovery() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        service.syncError = APIError(status: 409, code: "idempotency_conflict", message: "Conflict")
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true); _ = await sync.synchronize()
        XCTAssertTrue(sync.recoveryLocked); XCTAssertEqual(sync.pendingCount, 1)
        XCTAssertEqual(service.syncBodies.count, 1)
    }

    func testDefinitiveRejectionRecordsRequestAndDoesNotRewriteIt() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        service.syncError = APIError(status: 422, code: "observation_expired", message: "Refresh")
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertEqual(journal.value?.lastRejectionCode, "observation_expired")
        let rejected = try JSONDecoder().decode(RequestIdentity.self, from: service.syncBodies[0])
        _ = await sync.synchronize()
        let revised = try JSONDecoder().decode(RequestIdentity.self, from: service.syncBodies[1])
        XCTAssertNotEqual(rejected.requestId, revised.requestId)
    }

    func testHistoricalReceiptCannotReplaceNewerGarden() async throws {
        let service = SyncTestService(try ActivityContract.load()), editor = try editor(service)
        await editor.start()
        try editor.applyConfirmed(service.fixture.syncResult.garden)
        try editor.applyConfirmed(service.fixture.gardenBeforeSync)
        XCTAssertEqual(editor.confirmed?.stateVersion, service.fixture.syncResult.garden.stateVersion)
        XCTAssertEqual(editor.confirmed?.plants.first?.growthMicroUnits, "10000000")
    }

    func testCachedGardenSurvivesColdOfflineLaunchAndIsAccountScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forest-f5-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AccountDiskStore(directory: directory), service = SyncTestService(try ActivityContract.load())
        let original = try editor(service, disk: disk); await original.start()
        service.offline = true
        let reopened = try editor(service, disk: disk); await reopened.start()
        XCTAssertEqual(reopened.confirmed?.gardenId, original.confirmed?.gardenId)
        XCTAssertTrue(reopened.showingCached); XCTAssertFalse(reopened.canEdit)
        XCTAssertNil(try disk.load(ConfirmedGardenCache.self, kind: "garden", server: service.serverID, user: UUID()))
        XCTAssertNil(try disk.load(ConfirmedGardenCache.self, kind: "garden", server: "https://other.test", user: service.fixture.profile.userId))
        service.offline = false; await reopened.refresh()
        XCTAssertFalse(reopened.showingCached); XCTAssertTrue(reopened.canEdit)
        XCTAssertNil(reopened.message)
    }

    func testPausedUploadsRetainQueueAndBlockMembership() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start(); service.loseNextResponse = true
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true); await sync.setEnabled(false)
        let count = service.syncBodies.count
        _ = await sync.synchronize()
        XCTAssertEqual(service.syncBodies.count, count)
        XCTAssertEqual(sync.pendingCount, 1); XCTAssertFalse(editor.canEdit)
    }

    func testCleanupFailureRetainsOriginalRequestUntilReplaySucceeds() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start(); journal.failRemoval = true
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertEqual(sync.pendingCount, 1)
        journal.failRemoval = false
        _ = await sync.synchronize()
        XCTAssertEqual(service.syncBodies[0], service.syncBodies[1])
        XCTAssertEqual(sync.pendingCount, 0)
    }

    func testDatesBeforeEnrolmentAreExcludedFromNewUploads() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        let request = try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: XCTUnwrap(service.syncBodies.first))
        XCTAssertEqual(request.days.count, 1)
        XCTAssertEqual(request.days.first?.gameDate, service.fixture.enrolment.device.baselineDate)
    }

    func testOtherInstallationRequiresExplicitReplacement() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let original = service.fixture.enrolment.device
        let other = APIActivityDevice(deviceId: UUID(), installationId: UUID(), enrolledAt: original.enrolledAt,
                                      baselineDate: original.baselineDate, baselineObservedAt: original.baselineObservedAt,
                                      baselineSteps: original.baselineSteps, ready: true)
        service.setDevice(other)
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertTrue(sync.otherDeviceActive); XCTAssertFalse(editor.canEdit)
        XCTAssertTrue(service.enrolBodies.isEmpty); XCTAssertTrue(service.syncBodies.isEmpty)
        _ = await sync.synchronize(replacingDevice: true)
        let request = try ActivityWire.decoder().decode(ActivityEnrolmentRequest.self, from: XCTUnwrap(service.enrolBodies.first))
        XCTAssertEqual(request.expectedDeviceId, other.deviceId)
        XCTAssertEqual(request.steps, 3000)
        XCTAssertFalse(sync.otherDeviceActive)
    }

    func testOfflineCaptureSavesNewCumulativeObservationWithoutLocalGrowth() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        let growth = editor.confirmed?.plants.first?.growthMicroUnits
        service.offline = true; (health.provider as? SyncHealthProvider)?.amount = 4500
        _ = await sync.synchronize()
        let pending = try XCTUnwrap(journal.value?.operations.first)
        let request = try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: pending.body)
        XCTAssertEqual(request.days.last?.steps, 4500)
        XCTAssertEqual(editor.confirmed?.plants.first?.growthMicroUnits, growth)
        XCTAssertTrue(editor.showingCached); XCTAssertFalse(editor.canEdit)
    }

    func testSyntheticHealthCanNeverEnableUploads() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service)
        let health = ActivityStore(provider: FixtureHealthDataProvider())
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertFalse(sync.enabled); XCTAssertTrue(service.enrolBodies.isEmpty); XCTAssertTrue(service.syncBodies.isEmpty)
    }

    func testFileJournalRoundTripAndScopeTamperingAreDetected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forest-f5-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ActivityContract.load(), disk = AccountDiskStore(directory: directory)
        let journal = ActivityJournalStore(disk: disk), user = fixture.profile.userId
        let operation = PendingActivityOperation(id: fixture.syncRequest.requestId, kind: .sync,
                                                 body: try ActivityWire.encoder().encode(fixture.syncRequest), recapID: nil)
        let state = ActivityJournalState(enabled: true, status: fixture.status, operations: [operation])
        try journal.save(state, server: "https://one.test", user: user)
        let reopened = ActivityJournalStore(disk: disk)
        XCTAssertEqual(try reopened.load(server: "https://one.test", user: user)?.operations.first?.body, operation.body)
        XCTAssertNil(try reopened.load(server: "https://two.test", user: user))
        let original = disk.file(kind: "activity", server: "https://one.test", user: user)
        let wrongScope = disk.file(kind: "activity", server: "https://two.test", user: user)
        try FileManager.default.copyItem(at: original, to: wrongScope)
        XCTAssertThrowsError(try reopened.load(server: "https://two.test", user: user))
        var corrupt = state
        corrupt.operations = [.init(id: UUID(), kind: .sync, body: operation.body, recapID: nil)]
        try journal.save(corrupt, server: "https://one.test", user: user)
        XCTAssertThrowsError(try reopened.load(server: "https://one.test", user: user))
    }

    func testConcurrentSyncTriggersCoalesce() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start(); await health.connect()
        journal.value = ActivityJournalState(enabled: true, status: service.fixture.status)
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        service.pauseNext = true
        let first = Task { await sync.synchronize() }
        for _ in 0..<100 where service.gate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let second = Task { await sync.synchronize() }
        await Task.yield()
        let gate = try XCTUnwrap(service.gate); gate.resume(); service.gate = nil
        _ = await first.value; _ = await second.value
        XCTAssertEqual(service.syncBodies.count, 1)
    }

    func testRecapAcknowledgementNeverChangesGrowth() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start()
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        await sync.setEnabled(true)
        XCTAssertFalse(sync.recaps.isEmpty)
        let growth = editor.confirmed?.plants.first?.growthMicroUnits
        let uploadCount = service.syncBodies.count
        (health.provider as? SyncHealthProvider)?.amount = 4500
        await sync.dismissRecaps()
        XCTAssertEqual(service.ackBodies.count, 1); XCTAssertTrue(sync.recaps.isEmpty)
        XCTAssertEqual(editor.confirmed?.plants.first?.growthMicroUnits, growth)
        XCTAssertEqual(service.syncBodies.count, uploadCount)
    }

    func testLogoutDuringSyncRetainsTheOriginalJournalAndIgnoresLateGrowth() async throws {
        let service = SyncTestService(try ActivityContract.load()), journal = MemoryActivityJournal()
        let editor = try editor(service), health = health(service.fixture)
        await editor.start(); await health.connect()
        journal.value = ActivityJournalState(enabled: true, status: service.fixture.status)
        let sync = coordinator(service, editor: editor, health: health, journal: journal)
        let growth = editor.confirmed?.plants.first?.growthMicroUnits
        service.pauseNext = true
        let pending = Task { await sync.synchronize() }
        for _ in 0..<1000 where service.gate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let operation = try XCTUnwrap(journal.value?.operations.first)
        sync.deactivate(); editor.deactivate()
        let gate = try XCTUnwrap(service.gate); gate.resume(); service.gate = nil
        let result = await pending.value
        XCTAssertFalse(result)
        XCTAssertEqual(journal.value?.operations.first?.id, operation.id)
        XCTAssertEqual(journal.value?.operations.first?.body, operation.body)
        XCTAssertEqual(editor.confirmed?.plants.first?.growthMicroUnits, growth)
        XCTAssertFalse(editor.canEdit)
    }
}

final class ActivityWireTests: XCTestCase {
    func testOptionalQuantitiesAreIndependentAndConservative() throws {
        XCTAssertEqual(ActivityWire.quantity(1234.5679), "1234.567")
        XCTAssertNil(ActivityWire.quantity(.nan))
        XCTAssertNil(ActivityWire.quantity(-1))
        let day = ActivityDayUpload(gameDate: "2026-10-25", steps: 1000,
                                    walkingRunningDistanceMetres: nil, activeEnergyKcal: "100.000")
        let decoded = try ActivityWire.decoder().decode(ActivityDayUpload.self, from: ActivityWire.encoder().encode(day))
        XCTAssertEqual(decoded.steps, 1000)
        XCTAssertNil(decoded.walkingRunningDistanceMetres)
        XCTAssertEqual(decoded.activeEnergyKcal, "100.000")
    }

    func testWorkoutWireExcludesManualAndBoundsSegmentsWithoutBlockingSteps() throws {
        let start = Date(timeIntervalSince1970: 1_793_000_000.0004)
        func observation(manual: Bool? = nil, segments: [WorkoutSegmentUpload] = []) -> WorkoutObservation {
            WorkoutObservation(id: UUID(), activityType: 37, title: "Run", isRunning: true,
                start: start, end: start.addingTimeInterval(600.0004), durationSeconds: 600,
                distanceMetres: nil, sourceName: "Test", sourceBundleIdentifier: "test.recorded",
                wasUserEntered: manual, hasSegments: !segments.isEmpty, segments: segments)
        }
        XCTAssertNil(ActivityWire.workout(observation(manual: true)))
        XCTAssertNotNil(ActivityWire.workout(observation(manual: false)))
        let upload = try XCTUnwrap(ActivityWire.workout(observation()))
        XCTAssertNil(upload.wasUserEntered)
        let decoded = try ActivityWire.decoder().decode(WorkoutUpload.self, from: ActivityWire.encoder().encode(upload))
        XCTAssertLessThanOrEqual(decoded.durationMilliseconds, Int64((decoded.end.timeIntervalSince(decoded.start) * 1000).rounded()))
        let segment = WorkoutSegmentUpload(originalType: 37, start: start, end: start.addingTimeInterval(1), durationMilliseconds: 1000)
        XCTAssertNil(ActivityWire.workout(observation(segments: Array(repeating: segment, count: 257))))
        let bounded = try XCTUnwrap(ActivityWire.workout(observation(segments: Array(repeating: segment, count: 256))))
        XCTAssertLessThanOrEqual(bounded.segments.reduce(0) { $0 + $1.durationMilliseconds }, bounded.durationMilliseconds)
    }

    func testFractionalAndWholeSecondTimestampDecoding() throws {
        struct Value: Decodable { let date: Date }
        for value in ["2026-10-22T04:00:00Z", "2026-10-22T04:00:00.123456+00:00", "2026-10-22T12:00:00+08:00"] {
            let data = Data("{\"date\":\"\(value)\"}".utf8)
            XCTAssertNoThrow(try ActivityWire.decoder().decode(Value.self, from: data))
        }
    }
    func testGameDateUsesAccountTimezoneRatherThanPhoneTimezone() {
        let date = Date(timeIntervalSince1970: 1_792_627_200)
        let singapore = ActivityWire.gameDate(date, timeZone: TimeZone(identifier: "Asia/Singapore")!)
        let pacific = ActivityWire.gameDate(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertNotEqual(singapore, pacific)
    }
    func testExactProgressAndTerminalAdult() {
        XCTAssertNil(ExactAmount.integer("1e6")); XCTAssertNil(ExactAmount.integer("9223372036854775808"))
        let growing = APIGrowthProgress(stageStartMicroUnits: "100", nextStageMicroUnits: "400", maximumGrowthMicroUnits: "1000")
        XCTAssertEqual(growing.fraction(growth: "250"), 0.5)
        let adult = APIGrowthProgress(stageStartMicroUnits: "1000", nextStageMicroUnits: nil, maximumGrowthMicroUnits: "1000")
        XCTAssertEqual(adult.fraction(growth: "1000"), 1)
        XCTAssertNil(adult.fraction(growth: "999"))
    }
}
