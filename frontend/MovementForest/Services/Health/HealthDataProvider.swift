import Foundation
import Combine

@MainActor
protocol HealthDataProviding {
    var isAvailable: Bool { get }
    var isFixture: Bool { get }
    func requestReadAccess() async throws
    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport
    func readStepObservation(now: Date, timeZone: TimeZone) async -> ActivityReport
    func observeChanges(_ handler: @escaping @MainActor () async -> Void)
}

extension HealthDataProviding {
    func observeChanges(_ handler: @escaping @MainActor () async -> Void) { }
    func readStepObservation(now: Date, timeZone: TimeZone) async -> ActivityReport {
        await readActivity(now: now, timeZone: timeZone)
    }
}

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var report: ActivityReport?
    @Published private(set) var isLoading = false
    @Published private(set) var hasRequestedAccess: Bool
    @Published private(set) var requestIssue: String?
    let provider: any HealthDataProviding
    private(set) var timeZone: TimeZone
    private let defaults: UserDefaults
    private let requestKey = "health.readRequestAttempted.v1"
    private struct ReadKey: Hashable {
        let timeZone: String
        let optional: Bool
    }
    private var reads: [ReadKey: (id: UUID, task: Task<ActivityReport, Never>)] = [:]
    private var reportGeneration = UUID()

    init(provider: any HealthDataProviding, defaults: UserDefaults = .standard,
         timeZone: TimeZone = .current) {
        self.provider = provider
        self.defaults = defaults
        self.timeZone = timeZone
        hasRequestedAccess = provider.isFixture ? false : defaults.bool(forKey: requestKey)
    }

    func connect() async {
        guard !isLoading, provider.isAvailable else { return }
        isLoading = true
        requestIssue = nil
        defer { isLoading = false }
        hasRequestedAccess = true
        if !provider.isFixture { defaults.set(true, forKey: requestKey) }
        do {
            try await provider.requestReadAccess()
            // Completing this request does not establish read authorization.
            _ = await read(timeZone: timeZone, includingOptional: true)
        } catch {
            requestIssue = "The Health access request could not finish. Try again, or review this app’s access in Health."
        }
    }

    func refresh() async {
        guard hasRequestedAccess, provider.isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        requestIssue = nil
        _ = await read(timeZone: timeZone, includingOptional: true)
    }

    func readForUpload(timeZone: TimeZone, includingOptional: Bool = false) async -> ActivityReport {
        await read(timeZone: timeZone, includingOptional: includingOptional)
    }

    private func read(timeZone: TimeZone, includingOptional: Bool) async -> ActivityReport {
        if self.timeZone.identifier != timeZone.identifier {
            self.timeZone = timeZone; reportGeneration = UUID()
        }
        let generation = reportGeneration
        let full = ReadKey(timeZone: timeZone.identifier, optional: true)
        let key = !includingOptional && reads[full] != nil ? full :
            ReadKey(timeZone: timeZone.identifier, optional: includingOptional)
        let current: (id: UUID, task: Task<ActivityReport, Never>)
        if let existing = reads[key] { current = existing }
        else {
            let id = UUID(), provider = provider
            let task = Task {
                LifecycleDiagnostics.event("health read started id=\(id) optional=\(key.optional)")
                let result: ActivityReport
                if key.optional { result = await provider.readActivity(now: Date(), timeZone: timeZone) }
                else { result = await provider.readStepObservation(now: Date(), timeZone: timeZone) }
                LifecycleDiagnostics.event("health read ended id=\(id)")
                return result
            }
            current = (id, task); reads[key] = current
        }
        // Shared reads are owned by this store, rather than one presentation waiter.
        let result = await current.task.value
        if reads[key]?.id == current.id { reads.removeValue(forKey: key) }
        guard !Task.isCancelled, reportGeneration == generation else { return result }
        if key.optional { report = result }
        else {
            let previous = report?.timeZoneIdentifier == timeZone.identifier ? report : nil
            report = ActivityReport(observedAt: result.observedAt, timeZoneIdentifier: result.timeZoneIdentifier,
                                    days: result.days, workouts: previous?.workouts ?? [], stepsIssue: result.stepsIssue,
                                    workoutsIssue: previous?.workoutsIssue, isFixture: result.isFixture)
        }
        return result
    }
}

@MainActor
final class FixtureHealthDataProvider: HealthDataProviding {
    enum Scenario { case populated, empty, failure, unavailable }
    let scenario: Scenario
    var isAvailable: Bool { scenario != .unavailable }
    let isFixture = true
    init(scenario: Scenario = .populated) { self.scenario = scenario }
    func requestReadAccess() async throws { }
    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport {
        let amounts: [Double] = [3210, 5720, 4080, 6910, 5200, 8040, 2450]
        let days = ActivityCalendar.days(endingAt: now, count: 7, timeZone: timeZone).enumerated().map {
            ActivityDay(start: $0.element.start, end: $0.element.end,
                        steps: scenario == .populated ? amounts[$0.offset] : nil)
        }
        let workouts = scenario == .populated ? [WorkoutObservation(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
            activityType: 37, title: "Running", isRunning: true,
            start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-5400),
            durationSeconds: 1800, distanceMetres: 4100,
            sourceName: "Sample source", sourceBundleIdentifier: "example.fixture", wasUserEntered: false
        )] : []
        let issue: String? = scenario == .failure ? "Sample query failure. Try refreshing." : nil
        return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier, days: days,
                              workouts: workouts, stepsIssue: issue, workoutsIssue: issue, isFixture: true)
    }
}
