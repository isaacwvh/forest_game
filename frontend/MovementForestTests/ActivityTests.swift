import XCTest
import HealthKit
@testable import MovementForest

final class ActivityTests: XCTestCase {
    @MainActor
    func testRecordedWorkoutQueryExcludesManualEntriesButKeepsFalseAndMissingFlags() {
        let end = Date(timeIntervalSince1970: 1_792_627_200)
        let start = end.addingTimeInterval(-30 * 24 * 60 * 60)
        let predicate = HealthKitService.recordedWorkoutPredicate(start: start, end: end)
        let cases: [(metadata: [String: Any]?, included: Bool)] = [
            ([HKMetadataKeyWasUserEntered: NSNumber(value: true)], false),
            ([HKMetadataKeyWasUserEntered: NSNumber(value: false)], true),
            ([:], true),
            (nil, true)
        ]
        for testCase in cases {
            let workout = HKWorkout(activityType: .running, start: end.addingTimeInterval(-1800),
                                    end: end.addingTimeInterval(-60), duration: 1740,
                                    totalEnergyBurned: nil, totalDistance: nil, metadata: testCase.metadata)
            XCTAssertEqual(predicate.evaluate(with: workout), testCase.included)
        }
        let oldWorkout = HKWorkout(activityType: .running, start: start.addingTimeInterval(-1800),
                                   end: start.addingTimeInterval(-60))
        let futureWorkout = HKWorkout(activityType: .running, start: end.addingTimeInterval(60),
                                      end: end.addingTimeInterval(1800))
        XCTAssertFalse(predicate.evaluate(with: oldWorkout))
        XCTAssertFalse(predicate.evaluate(with: futureWorkout))
    }

    @MainActor
    func testEmptyHealthIsNotZeroAndDoesNotImplyDeniedPermission() async {
        let provider = FixtureHealthDataProvider(scenario: .empty)
        let report = await provider.readActivity(now: Date(), timeZone: .current)
        XCTAssertEqual(report.days.count, 7)
        XCTAssertNil(report.todaySteps)
        XCTAssertTrue(report.days.allSatisfy { $0.steps == nil })
        XCTAssertNil(report.stepsIssue)
        XCTAssertTrue(report.workouts.isEmpty)
    }

    @MainActor
    func testRepeatedReadsDoNotAccumulateWorkoutsOrSteps() async {
        let provider = FixtureHealthDataProvider()
        let now = Date()
        let first = await provider.readActivity(now: now, timeZone: .current)
        let second = await provider.readActivity(now: now, timeZone: .current)
        XCTAssertEqual(first.days, second.days)
        XCTAssertEqual(first.workouts, second.workouts)
        XCTAssertEqual(second.workouts.count, 1)
        XCTAssertEqual(second.todaySteps, 2450)
    }

    @MainActor
    func testRefreshDoesNotRequestAccessBeforeUserAction() async {
        let provider = CountingHealthProvider()
        let suite = "MovementForest.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityStore(provider: provider, defaults: defaults)
        await store.refresh()
        XCTAssertEqual(provider.reads, 0)
        XCTAssertEqual(provider.requests, 0)
        await store.connect()
        XCTAssertEqual(provider.requests, 1)
        XCTAssertEqual(provider.reads, 1)
        XCTAssertTrue(store.hasRequestedAccess)
        await store.refresh()
        XCTAssertEqual(provider.requests, 1)
        XCTAssertEqual(provider.reads, 2)
    }

    @MainActor
    func testFailureIsDistinctFromEmpty() async {
        let report = await FixtureHealthDataProvider(scenario: .failure).readActivity(now: Date(), timeZone: .current)
        XCTAssertNotNil(report.stepsIssue)
        XCTAssertNotNil(report.workoutsIssue)
        XCTAssertNil(report.todaySteps)
    }

    @MainActor
    func testConcurrentUploadAndDiagnosticReadsShareCompatibleFullObservation() async throws {
        let provider = PausedHealthProvider()
        let store = ActivityStore(provider: provider)
        let zone = TimeZone(secondsFromGMT: 0)!
        let first = Task { await store.readForUpload(timeZone: zone, includingOptional: true) }
        try await waitForReads(provider, count: 1)
        let second = Task { await store.readForUpload(timeZone: zone, includingOptional: true) }
        let steps = Task { await store.readForUpload(timeZone: zone) }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(provider.fullReads, 1)
        XCTAssertEqual(provider.stepReads, 0)
        provider.finishReads()
        let reports = await (first.value, second.value, steps.value)
        XCTAssertEqual(reports.0.timeZoneIdentifier, zone.identifier)
        XCTAssertEqual(reports.0.observedAt, reports.1.observedAt)
        XCTAssertEqual(reports.0.observedAt, reports.2.observedAt)
    }

    @MainActor
    func testStepsOnlyAndDifferentTimezoneReadsCannotReplaceRequiredFullRead() async throws {
        let provider = PausedHealthProvider()
        let store = ActivityStore(provider: provider)
        let firstZone = TimeZone(secondsFromGMT: 0)!, nextZone = TimeZone(secondsFromGMT: 3600)!
        let steps = Task { await store.readForUpload(timeZone: firstZone) }
        try await waitForReads(provider, count: 1)
        let full = Task { await store.readForUpload(timeZone: firstZone, includingOptional: true) }
        try await waitForReads(provider, count: 2)
        let next = Task { await store.readForUpload(timeZone: nextZone, includingOptional: true) }
        try await waitForReads(provider, count: 3)
        XCTAssertEqual(provider.stepReads, 1)
        XCTAssertEqual(provider.fullReads, 2)
        provider.finishReads()
        let reports = await (steps.value, full.value, next.value)
        XCTAssertEqual(reports.0.timeZoneIdentifier, firstZone.identifier)
        XCTAssertEqual(reports.1.timeZoneIdentifier, firstZone.identifier)
        XCTAssertEqual(reports.2.timeZoneIdentifier, nextZone.identifier)
        XCTAssertEqual(store.report?.timeZoneIdentifier, nextZone.identifier)
    }

    @MainActor
    private func waitForReads(_ provider: PausedHealthProvider, count: Int) async throws {
        for _ in 0..<300 {
            if provider.fullReads + provider.stepReads >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Health reads did not start")
        provider.finishReads()
        throw URLError(.timedOut)
    }
}

@MainActor
private final class PausedHealthProvider: HealthDataProviding {
    let isAvailable = true
    let isFixture = false
    var fullReads = 0
    var stepReads = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    func requestReadAccess() async throws { }
    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport {
        fullReads += 1
        return await read(now: now, timeZone: timeZone)
    }
    func readStepObservation(now: Date, timeZone: TimeZone) async -> ActivityReport {
        stepReads += 1
        return await read(now: now, timeZone: timeZone)
    }
    private func read(now: Date, timeZone: TimeZone) async -> ActivityReport {
        await withCheckedContinuation { pending.append($0) }
        return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier,
                              days: [], workouts: [], stepsIssue: nil, workoutsIssue: nil, isFixture: false)
    }
    func finishReads() {
        let current = pending; pending.removeAll()
        current.forEach { $0.resume() }
    }
}

@MainActor
private final class CountingHealthProvider: HealthDataProviding {
    let isAvailable = true
    let isFixture = false
    var reads = 0
    var requests = 0
    func requestReadAccess() async throws { requests += 1 }
    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport {
        reads += 1
        return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier,
                              days: [], workouts: [], stepsIssue: nil, workoutsIssue: nil, isFixture: true)
    }
}
