import Foundation

struct ActivityDay: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let end: Date
    /// nil means no readable data; it must never be silently changed to zero.
    let steps: Double?
    var walkingRunningDistanceMetres: Double? = nil
    var activeEnergyKcal: Double? = nil
    var flightsClimbed: Double? = nil
}

struct WorkoutObservation: Identifiable, Equatable {
    let id: UUID
    let activityType: UInt
    let title: String
    let isRunning: Bool
    let start: Date
    let end: Date
    let durationSeconds: Double
    let distanceMetres: Double?
    let sourceName: String
    let sourceBundleIdentifier: String
    let wasUserEntered: Bool?
    var hasSegments: Bool = false
    var segments: [WorkoutSegmentUpload] = []
}

struct ActivityReport {
    let observedAt: Date
    let timeZoneIdentifier: String
    let days: [ActivityDay]
    let workouts: [WorkoutObservation]
    let stepsIssue: String?
    let workoutsIssue: String?
    let isFixture: Bool
    var todaySteps: Double? { days.last?.steps }
    var metricIssues: [String: String] = [:]
}

enum ActivityCalendar {
    static func dayLabel(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: date)
    }
    static func calendar(timeZone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }

    static func days(endingAt now: Date, count: Int, timeZone: TimeZone) -> [DateInterval] {
        guard count > 0 else { return [] }
        let calendar = calendar(timeZone: timeZone)
        let today = calendar.startOfDay(for: now)
        return (0..<count).compactMap { index in
            guard let start = calendar.date(byAdding: .day, value: index - count + 1, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: min(end, now))
        }
    }
}
