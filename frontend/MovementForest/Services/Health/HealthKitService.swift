import Foundation
import HealthKit

@MainActor
final class HealthKitService: HealthDataProviding {
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    let isFixture = false
    private var observers: [HKObserverQuery] = []

    func requestReadAccess() async throws {
        guard isAvailable, let steps = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            throw ForestError.invalidData("Health data is unavailable on this device.")
        }
        let quantities = [HKQuantityTypeIdentifier.distanceWalkingRunning, .activeEnergyBurned, .flightsClimbed]
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        let types = Set<HKObjectType>([steps, HKObjectType.workoutType()] + quantities)
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func observeChanges(_ handler: @escaping @MainActor () async -> Void) {
        for observer in observers { store.stop(observer) }
        observers = []
        let types: [HKSampleType] = [HKQuantityTypeIdentifier.stepCount, .distanceWalkingRunning,
                                    .activeEnergyBurned, .flightsClimbed]
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) } + [HKObjectType.workoutType()]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in await handler(); completion() }
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
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
        var workoutsIssue: String? = nil
        async let distance = optionalQuantity(intervals: intervals, timeZone: timeZone, now: now,
                                              identifier: .distanceWalkingRunning, unit: .meter())
        async let energy = optionalQuantity(intervals: intervals, timeZone: timeZone, now: now,
                                            identifier: .activeEnergyBurned, unit: .kilocalorie())
        async let flights = optionalQuantity(intervals: intervals, timeZone: timeZone, now: now,
                                             identifier: .flightsClimbed, unit: .count())
        async let imported = readWorkouts(now: now, timeZone: timeZone)
        do { days = try await readSteps(intervals: intervals, timeZone: timeZone, now: now) }
        catch { stepsIssue = "Steps could not be read. Unlock your iPhone and refresh. You can also review access in Health." }
        do { workouts = try await imported }
        catch { workoutsIssue = "Workouts could not be read. Unlock your iPhone and refresh." }
        let optional = await (distance, energy, flights)
        for index in days.indices {
            days[index].walkingRunningDistanceMetres = optional.0.0[index]
            days[index].activeEnergyKcal = optional.1.0[index]
            days[index].flightsClimbed = optional.2.0[index]
        }
        var report = ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier, days: days,
                                    workouts: workouts, stepsIssue: stepsIssue, workoutsIssue: workoutsIssue, isFixture: false)
        for (metric, issue) in [("walking_running_distance_km", optional.0.1),
                                ("active_energy_kcal", optional.1.1), ("flights_climbed", optional.2.1)] {
            if let issue = issue { report.metricIssues[metric] = issue }
        }
        return report
    }

    func readStepObservation(now: Date, timeZone: TimeZone) async -> ActivityReport {
        let intervals = ActivityCalendar.days(endingAt: now, count: 7, timeZone: timeZone)
        do {
            guard isAvailable else { throw ForestError.invalidData("Health data is unavailable on this device.") }
            let days = try await readSteps(intervals: intervals, timeZone: timeZone, now: now)
            return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier, days: days,
                                  workouts: [], stepsIssue: nil, workoutsIssue: nil, isFixture: false)
        } catch {
            return ActivityReport(observedAt: now, timeZoneIdentifier: timeZone.identifier,
                                  days: intervals.map { ActivityDay(start: $0.start, end: $0.end, steps: nil) },
                                  workouts: [], stepsIssue: "Steps could not be read. Unlock your iPhone and try again.",
                                  workoutsIssue: nil, isFixture: false)
        }
    }

    private func readSteps(intervals: [DateInterval], timeZone: TimeZone, now: Date) async throws -> [ActivityDay] {
        let totals = try await readQuantity(intervals: intervals, timeZone: timeZone, now: now,
                                             identifier: .stepCount, unit: .count())
        return intervals.enumerated().map { ActivityDay(start: $0.element.start, end: $0.element.end,
                                                        steps: totals[$0.offset]) }
    }

    private func optionalQuantity(intervals: [DateInterval], timeZone: TimeZone, now: Date,
                                  identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> ([Double?], String?) {
        do { return (try await readQuantity(intervals: intervals, timeZone: timeZone, now: now,
                                             identifier: identifier, unit: unit), nil) }
        catch { return (Array(repeating: nil, count: intervals.count), "This quantity could not be read. Unlock your iPhone and review Health access.") }
    }

    private func readQuantity(intervals: [DateInterval], timeZone: TimeZone, now: Date,
                              identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> [Double?] {
        guard let first = intervals.first, let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return Array(repeating: nil, count: intervals.count) }
        let calendar = ActivityCalendar.calendar(timeZone: timeZone)
        let runner = HealthQueryRunner<[Double?]>(store: store)
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
                    collection.statistics(for: interval.start)?.sumQuantity()?.doubleValue(for: unit)
                }
                finish(.success(days))
            }
            return query
        }
    }

    private func readWorkouts(now: Date, timeZone: TimeZone) async throws -> [WorkoutObservation] {
        let calendar = ActivityCalendar.calendar(timeZone: timeZone)
        guard let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else { return [] }
        let runner = HealthQueryRunner<[WorkoutObservation]>(store: store)
        return try await runner.run { finish in
            // Filter manual entries before selection. The bounded seven-day read
            // has no result truncation; uploads are durably chunked by the coordinator.
            let predicate = Self.recordedWorkoutPredicate(start: start, end: now)
            return HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit,
                                 sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error = error { finish(.failure(error)); return }
                let workouts = (samples as? [HKWorkout] ?? []).filter { $0.endDate <= now }.map { workout in
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
                    let segments = Self.eligibleSegments(workout)
                    return WorkoutObservation(id: workout.uuid, activityType: type.rawValue, title: title,
                                              isRunning: type == .running, start: workout.startDate, end: workout.endDate,
                                              durationSeconds: workout.duration, distanceMetres: distance,
                                              sourceName: workout.sourceRevision.source.name,
                                              sourceBundleIdentifier: workout.sourceRevision.source.bundleIdentifier,
                                              wasUserEntered: (workout.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue,
                                              hasSegments: true, segments: segments)
                }
                finish(.success(workouts))
            }
        }
    }

    static func recordedWorkoutPredicate(start: Date, end: Date) -> NSPredicate {
        let dates = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let manuallyEntered = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyWasUserEntered,
                                                         allowedValues: [NSNumber(value: true)])
        // Missing metadata remains eligible for this preliminary guard; it is not proof of authenticity.
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            dates, NSCompoundPredicate(notPredicateWithSubpredicate: manuallyEntered)
        ])
    }

    nonisolated private static func eligibleSegments(_ workout: HKWorkout) -> [WorkoutSegmentUpload] {
        let events = (workout.workoutEvents ?? []).sorted { $0.dateInterval.start < $1.dateInterval.start }
        var active = true
        var cursor = workout.startDate
        var intervals: [DateInterval] = []
        for event in events {
            let instant = min(workout.endDate, max(workout.startDate, event.dateInterval.start))
            switch event.type {
            case .pause, .motionPaused:
                if active && instant > cursor { intervals.append(DateInterval(start: cursor, end: instant)) }
                active = false
            case .resume, .motionResumed:
                if !active { cursor = instant }
                active = true
            default: break
            }
        }
        if active && cursor < workout.endDate { intervals.append(DateInterval(start: cursor, end: workout.endDate)) }
        let activities = workout.workoutActivities
        var result: [WorkoutSegmentUpload] = []
        for interval in intervals {
            if activities.isEmpty {
                let elapsed = workout.endDate.timeIntervalSince(workout.startDate)
                let activeTotal = intervals.reduce(0) { $0 + $1.duration }
                let density = min(1, workout.duration / max(activeTotal, 0.001))
                if elapsed > 0 {
                    result.append(WorkoutSegmentUpload(originalType: Int(workout.workoutActivityType.rawValue),
                        start: interval.start, end: interval.end,
                        durationMilliseconds: Int64((interval.duration * density * 1000).rounded(.down))))
                }
            } else {
                for activity in activities {
                    let end = min(interval.end, activity.endDate ?? workout.endDate)
                    let start = max(interval.start, activity.startDate)
                    guard start < end else { continue }
                    let activeSpan = intervals.reduce(0.0) { total, candidate in
                        let left = max(candidate.start, activity.startDate)
                        let right = min(candidate.end, activity.endDate ?? workout.endDate)
                        return total + max(0, right.timeIntervalSince(left))
                    }
                    let density = min(1, activity.duration / max(activeSpan, 0.001))
                    result.append(WorkoutSegmentUpload(originalType: Int(activity.workoutConfiguration.activityType.rawValue),
                        start: start, end: end,
                        durationMilliseconds: Int64((end.timeIntervalSince(start) * density * 1000).rounded(.down))))
                }
            }
        }
        return result
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
