import Foundation
import HealthKit

@MainActor
final class HealthKitService: HealthDataProviding {
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    let isFixture = false

    func requestReadAccess() async throws {
        guard isAvailable, let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            throw ForestError.invalidData("Health data is unavailable on this device.")
        }
        let types: Set<HKObjectType> = [steps, HKObjectType.workoutType()]
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func readActivity(now: Date, timeZone: TimeZone) async -> ActivityReport {
        guard isAvailable else {
            return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier, days: [], workouts: [],
                                  stepsIssue: "Health data is unavailable on this device.",
                                  workoutsIssue: "Health data is unavailable on this device.", isFixture: false)
        }
        // Separate failures: a workout read must not hide successfully read steps.
        let intervals = ActivityCalendar.days(endingAt: now, count: 7, timeZone: timeZone)
        var days = intervals.map { ActivityDay(start: $0.start, end: $0.end, steps: nil) }
        var workouts: [WorkoutObservation] = []
        var stepsIssue: String?
        var workoutsIssue: String?
        do { days = try await readSteps(intervals: intervals, timeZone: timeZone, now: now) }
        catch { stepsIssue = "Steps could not be read. Unlock your iPhone and refresh. You can also review access in Health." }
        do { workouts = try await readWorkouts(now: now, timeZone: timeZone) }
        catch { workoutsIssue = "Workouts could not be read. Unlock your iPhone and refresh." }
        return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier, days: days,
                              workouts: workouts, stepsIssue: stepsIssue, workoutsIssue: workoutsIssue, isFixture: false)
    }

    private func readSteps(intervals: [DateInterval], timeZone: TimeZone, now: Date) async throws -> [ActivityDay] {
        guard let first = intervals.first, let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [] }
        let calendar = ActivityCalendar.calendar(timeZone: timeZone)
        let runner = HealthQueryRunner<[ActivityDay]>(store: store)
        return try await runner.run { finish in
            let predicate = HKQuery.predicateForSamples(withStart: first.start, end: now, options: [])
            var interval = DateComponents()
            interval.day = 1
            interval.calendar = calendar
            interval.timeZone = timeZone
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: first.start,
                                                    intervalComponents: interval)
            query.initialResultsHandler = { _, collection, error in
                if let error = error { finish(.failure(error)); return }
                guard let collection = collection else {
                    finish(.failure(ForestError.invalidData("No statistics response."))); return
                }
                let days = intervals.map { interval in
                    ActivityDay(start: interval.start, end: interval.end,
                                steps: collection.statistics(for: interval.start)?.sumQuantity()?.doubleValue(for: .count()))
                }
                finish(.success(days))
            }
            return query
        }
    }

    private func readWorkouts(now: Date, timeZone: TimeZone) async throws -> [WorkoutObservation] {
        let calendar = ActivityCalendar.calendar(timeZone: timeZone)
        guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return [] }
        let runner = HealthQueryRunner<[WorkoutObservation]>(store: store)
        return try await runner.run { finish in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
            return HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 100,
                                 sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error = error { finish(.failure(error)); return }
                let workouts = (samples as? [HKWorkout] ?? []).map { workout in
                    let type = workout.workoutActivityType
                    let title: String
                    switch type {
                    case .running: title = "Running"
                    case .walking: title = "Walking"
                    case .cycling: title = "Cycling"
                    case .hiking: title = "Hiking"
                    case .swimming: title = "Swimming"
                    case .traditionalStrengthTraining, .functionalStrengthTraining: title = "Strength training"
                    case .yoga: title = "Yoga"
                    default: title = "Workout (type \(type.rawValue))"
                    }
                    // Optional aggregate attached to this workout, never a new base-step input.
                    let distanceType: HKQuantityTypeIdentifier?
                    switch type {
                    case .running, .walking, .hiking: distanceType = .distanceWalkingRunning
                    case .cycling: distanceType = .distanceCycling
                    case .swimming: distanceType = .distanceSwimming
                    default: distanceType = nil
                    }
                    let distance = distanceType.flatMap { HKQuantityType.quantityType(forIdentifier: $0) }
                        .flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
                    return WorkoutObservation(id: workout.uuid, activityType: type.rawValue, title: title,
                                              isRunning: type == .running, start: workout.startDate, end: workout.endDate,
                                              durationSeconds: workout.duration, distanceMetres: distance,
                                              sourceName: workout.sourceRevision.source.name,
                                              sourceBundleIdentifier: workout.sourceRevision.source.bundleIdentifier,
                                              wasUserEntered: (workout.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue ?? false)
                }
                finish(.success(workouts))
            }
        }
    }
}

/// One-shot reads stop their query after completion, cancellation or timeout.
/// All completion paths meet on MainActor so a continuation resumes only once.
@MainActor
private final class HealthQueryRunner<Value> {
    private let store: HKHealthStore
    private var query: HKQuery?
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeout: Task<Void, Never>?
    init(store: HKHealthStore) { self.store = store }

    func run(_ build: (@escaping (Result<Value, Error>) -> Void) -> HKQuery) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let query = build { [weak self] result in
                    Task { @MainActor in self?.finish(result) }
                }
                self.query = query
                store.execute(query)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                    catch { return }
                    self?.finish(.failure(ForestError.invalidData("Health query timed out.")))
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError())) }
        })
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        if let query = query { store.stop(query) }
        query = nil
        continuation.resume(with: result)
    }
}
