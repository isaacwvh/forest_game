import Foundation
import Combine

@MainActor
protocol HealthDataProviding {
    var isAvailable: Bool { get }
    var isFixture: Bool { get }
    func requestReadAccess() async throws
    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport
    func readStepObservation(now: Date, timeZone: TimeZone) async -> ActivityReport
}

extension HealthDataProviding {
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
            report = await provider.readActivity(now: Date(), timeZone: timeZone)
        } catch {
            requestIssue = "The Health access request could not finish. Try again, or review this app’s access in Health."
        }
    }

    func refresh() async {
        guard hasRequestedAccess, provider.isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        requestIssue = nil
        report = await provider.readActivity(now: Date(), timeZone: timeZone)
    }

    func readForUpload(timeZone: TimeZone) async -> ActivityReport {
        self.timeZone = timeZone
        let result = await provider.readStepObservation(now: Date(), timeZone: timeZone)
        // Preserve workout diagnostics from a previous local read.
        report = ActivityReport(observedAt: result.observedAt, timeZoneIdentifier: result.timeZoneIdentifier,
                                days: result.days, workouts: report?.workouts ?? [], stepsIssue: result.stepsIssue,
                                workoutsIssue: report?.workoutsIssue, isFixture: result.isFixture)
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
