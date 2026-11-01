import Foundation

/// Read-only display quantities. Fraction strings are the server's exact metric
/// receipts; no display value is used to calculate or award growth.
enum ActivityDisplayAmount {
    static func decimal(_ raw: String) -> Decimal? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.count <= 38 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }), let numerator = Decimal(string: String(parts[0])) else { return nil }
        if parts.count == 1 { return numerator }
        guard let denominator = Decimal(string: String(parts[1])), denominator > 0 else { return nil }
        return numerator / denominator
    }
    static func text(_ amount: Decimal?, decimals: Int = 1) -> String {
        guard var value = amount, value >= 0 else { return "Unavailable" }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, decimals, .plain)
        if value > 0 && rounded == 0 {
            let minimum = decimals == 0 ? Decimal(1) : Decimal(1) / 10
            return "<" + minimum.formatted(.number)
        }
        return rounded.formatted(.number.precision(.fractionLength(0...decimals)))
    }
}

enum ActivityDisplayMetric: String, CaseIterable, Identifiable {
    case steps, distance, energy, flights, workouts, workoutMinutes
    var id: String { rawValue }
    var key: String {
        switch self {
        case .steps: return "steps"
        case .distance: return "walking_running_distance_km"
        case .energy: return "active_energy_kcal"
        case .flights: return "flights_climbed"
        case .workouts, .workoutMinutes: return "workout_minutes.*"
        }
    }
    var title: String {
        switch self {
        case .workouts: return "Recorded workouts (all)"
        case .workoutMinutes: return "Workout minutes"
        default: return ActivityMetricLabel.title(key)
        }
    }
    var unit: String {
        switch self {
        case .steps: return "steps"
        case .distance: return "km"
        case .energy: return "kcal"
        case .flights: return "flights"
        case .workouts: return "workouts"
        case .workoutMinutes: return "min"
        }
    }
    var decimals: Int { [.steps, .flights, .workouts].contains(self) ? 0 : 1 }
}

struct ActivityRecapSummary {
    let amounts: [ActivityDisplayMetric: Decimal]
    init(recaps: [APIRewardRecap]) {
        let unique = Dictionary(recaps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let complete = unique.allSatisfy { $0.payload.activitySummaryVersion == 1 }
        var totals: [ActivityDisplayMetric: Decimal] = complete
            ? Dictionary(uniqueKeysWithValues: ActivityDisplayMetric.allCases.map { ($0, Decimal(0)) }) : [.steps: 0]
        var seenDays = Set<String>(), seenWorkouts = Set<UUID>()
        var unavailable = Set<ActivityDisplayMetric>()
        for recap in unique {
            if recap.payload.activitySummaryVersion != 1 {
                for metric in [ActivityDisplayMetric.distance, .energy, .flights] {
                    if recap.payload.activityDays.contains(where: { $0.metrics?[metric.key] == nil }) {
                        unavailable.insert(metric)
                    }
                }
                if recap.payload.workouts == nil { unavailable.insert(.workouts) }
                if !recap.payload.activityDays.contains(where: { day in
                    day.metrics?.keys.contains(where: { $0.hasPrefix("workout_minutes.") }) == true
                }) { unavailable.insert(.workoutMinutes) }
            }
            for day in recap.payload.activityDays {
                let identity = day.activityCreditId?.uuidString ?? "\(recap.id):\(day.gameDate)"
                guard seenDays.insert(identity).inserted else { continue }
                totals[.steps, default: 0] += Decimal(day.newlyEligibleSteps)
                for metric in [ActivityDisplayMetric.distance, .energy, .flights] {
                    if let receipt = day.metrics?[metric.key],
                       let value = ActivityDisplayAmount.decimal(receipt.newlyEligible) {
                        totals[metric, default: 0] += value
                    }
                }
                // Typed duration receipts are disjoint server-credited intervals.
                for (key, receipt) in day.metrics ?? [:] where key.hasPrefix("workout_minutes.") {
                    if let value = ActivityDisplayAmount.decimal(receipt.newlyEligible) {
                        totals[.workoutMinutes, default: 0] += value
                    }
                }
            }
            for workout in recap.payload.workouts ?? [] {
                if workout.status == "accepted",
                   let minutes = workout.newlyEligibleMinutes.flatMap(ActivityDisplayAmount.decimal), minutes > 0,
                   seenWorkouts.insert(workout.workoutId).inserted {
                    totals[.workouts, default: 0] += 1
                }
            }
        }
        for metric in unavailable { totals.removeValue(forKey: metric) }
        amounts = totals
    }
}

struct ActivityDailyTotals {
    let amounts: [ActivityDisplayMetric: Decimal]
    init(report: ActivityReport?, timeZone: TimeZone, now: Date = Date()) {
        guard let report = report, report.timeZoneIdentifier == timeZone.identifier else { amounts = [:]; return }
        let calendar = ActivityCalendar.calendar(timeZone: timeZone)
        guard let day = report.days.first(where: { calendar.isDate($0.start, inSameDayAs: now) }) else {
            amounts = [:]; return
        }
        var totals: [ActivityDisplayMetric: Decimal] = [:]
        func store(_ metric: ActivityDisplayMetric, _ value: Double?) {
            if let value = value, value.isFinite, value >= 0 { totals[metric] = Decimal(value) }
        }
        if report.stepsIssue == nil { store(.steps, day.steps) }
        if report.includesOptionalActivity {
            if report.metricIssues[ActivityDisplayMetric.distance.key] == nil {
                store(.distance, day.walkingRunningDistanceMetres.map { $0 / 1000 })
            }
            if report.metricIssues[ActivityDisplayMetric.energy.key] == nil { store(.energy, day.activeEnergyKcal) }
            if report.metricIssues[ActivityDisplayMetric.flights.key] == nil { store(.flights, day.flightsClimbed) }
            if report.workoutsIssue == nil, let interval = calendar.dateInterval(of: .day, for: now) {
                let end = min(now, interval.end)
                let unique = Dictionary(report.workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let workouts = unique.values.filter {
                    $0.wasUserEntered != true && $0.start < end && $0.end > interval.start
                        && $0.end > $0.start && $0.durationSeconds.isFinite && $0.durationSeconds > 0
                }
                totals[.workouts] = Decimal(workouts.count)
                let seconds = workouts.reduce(0.0) { result, workout in
                    let overlap = max(0, min(end, workout.end).timeIntervalSince(max(interval.start, workout.start)))
                    let density = min(1, workout.durationSeconds / workout.end.timeIntervalSince(workout.start))
                    return result + overlap * density
                }
                totals[.workoutMinutes] = Decimal(seconds / 60)
            }
        }
        amounts = totals
    }
}

struct RecapGrowthDisplay {
    let existing: Double
    let added: Double
    let total: Double
    init?(row: ActivityRecapRow) {
        guard let end = row.endGrowth.flatMap(ExactAmount.integer),
              let maximum = row.maximumGrowth.flatMap(ExactAmount.integer), maximum > 0,
              let award = ExactAmount.integer(row.water), end <= maximum, award <= end else { return nil }
        existing = NSDecimalNumber(decimal: (end - award) / maximum).doubleValue
        added = NSDecimalNumber(decimal: award / maximum).doubleValue
        total = NSDecimalNumber(decimal: end / maximum).doubleValue
    }
}
