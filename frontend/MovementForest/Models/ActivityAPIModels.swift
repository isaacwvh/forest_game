import Foundation

enum ActivityWire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try value.encode(formatter.string(from: date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw ForestError.invalidData("The server returned an invalid activity timestamp.")
            }
            return date
        }
        return decoder
    }
    static func gameDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = ActivityCalendar.calendar(timeZone: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func steps(_ value: Double?) throws -> Int64? {
        guard let value = value else { return nil }
        guard value.isFinite, value >= 0, value <= 1_000_000_000 else {
            throw ForestError.invalidData("Health returned an invalid step total outside the supported range. Try reading again.")
        }
        // HealthKit count quantities are Doubles, including aggregated daily totals.
        // Floor the cumulative total once, never individual samples or deltas. A
        // later read recovers a whole step when the cumulative total crosses it;
        // existing server watermarks handle repeats and downward corrections.
        return Int64(value.rounded(.down))
    }
    static func quantity(_ value: Double?, maximum: Double = 999_999_999) -> String? {
        guard let value = value, value.isFinite, value >= 0, value <= maximum else { return nil }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                      (value * 1000).rounded(.down) / 1000)
    }
    static func workout(_ value: WorkoutObservation) -> WorkoutUpload? {
        let elapsed = value.end.timeIntervalSince(value.start)
        guard value.wasUserEntered != true, value.activityType <= 10_000,
              elapsed > 0, value.durationSeconds.isFinite, value.durationSeconds >= 0,
              value.durationSeconds <= 86_400, !value.sourceBundleIdentifier.isEmpty,
              value.sourceBundleIdentifier.count <= 255, value.segments.count <= 256,
              value.hasSegments || value.segments.isEmpty,
              value.segments.allSatisfy({ segment in
                  (0...10_000).contains(segment.originalType) && segment.start >= value.start &&
                  segment.end <= value.end && segment.start < segment.end &&
                  (0...86_400_000).contains(segment.durationMilliseconds) &&
                  Double(segment.durationMilliseconds) <= segment.end.timeIntervalSince(segment.start) * 1000 + 0.001
              }) else { return nil }
        // Match ISO8601DateFormatter's millisecond wire precision before bounding
        // durations. Sub-millisecond Health dates must not invalidate a whole sync.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func wireDate(_ date: Date) -> Date { formatter.date(from: formatter.string(from: date)) ?? date }
        let start = wireDate(value.start), end = wireDate(value.end)
        guard start < end else { return nil }
        let parentMilliseconds = min(Int64((end.timeIntervalSince(start) * 1000).rounded()),
                                     Int64((value.durationSeconds * 1000).rounded(.down)))
        let boundedSegments = value.segments.compactMap { segment -> WorkoutSegmentUpload? in
            let left = wireDate(segment.start), right = wireDate(segment.end)
            guard left < right else { return nil }
            return WorkoutSegmentUpload(originalType: segment.originalType, start: left, end: right,
                durationMilliseconds: min(segment.durationMilliseconds, Int64((right.timeIntervalSince(left) * 1000).rounded())))
        }
        let total = boundedSegments.reduce(Int64(0)) { $0 + $1.durationMilliseconds }
        let segments = total > parentMilliseconds && total > 0 ? boundedSegments.map {
            WorkoutSegmentUpload(originalType: $0.originalType, start: $0.start, end: $0.end,
                durationMilliseconds: Int64((Double($0.durationMilliseconds) * Double(parentMilliseconds) / Double(total)).rounded(.down)))
        } : boundedSegments
        return WorkoutUpload(workoutId: value.id, originalType: Int(value.activityType),
                             start: start, end: end,
                             durationMilliseconds: parentMilliseconds,
                             sourceBundleIdentifier: value.sourceBundleIdentifier,
                             wasUserEntered: value.wasUserEntered, hasSegments: value.hasSegments,
                             segments: segments)
    }
}

struct WorkoutSegmentUpload: Codable, Equatable {
    let originalType: Int
    let start: Date
    let end: Date
    let durationMilliseconds: Int64
}

struct WorkoutUpload: Codable, Equatable {
    let workoutId: UUID
    let originalType: Int
    let start: Date
    let end: Date
    let durationMilliseconds: Int64
    let sourceBundleIdentifier: String
    let wasUserEntered: Bool?
    let hasSegments: Bool
    let segments: [WorkoutSegmentUpload]
}

struct APIActivityDevice: Codable, Equatable {
    let deviceId: UUID
    let installationId: UUID
    let enrolledAt: Date
    let baselineDate: String?
    let baselineObservedAt: Date?
    let baselineSteps: Int64?
    let ready: Bool
}

struct APIActivityStatus: Codable {
    let serverTime: Date
    let gameTimezone: String
    let supportedMetrics: [String]
    let reconciliationDays: Int
    let queuedUploadMaxAgeDays: Int
    let device: APIActivityDevice?
    let activitySteps: String
    let firstMaturityCount: Int64
    let lastSyncAt: Date?
    var activityMetrics: [String: String]? = nil
}

struct ActivityDayUpload: Codable, Equatable {
    let gameDate: String
    let steps: Int64?
    var walkingRunningDistanceMetres: String? = nil
    var activeEnergyKcal: String? = nil
    var flightsClimbed: Int64? = nil
    enum CodingKeys: String, CodingKey {
        case gameDate, steps, walkingRunningDistanceMetres, activeEnergyKcal, flightsClimbed
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(gameDate, forKey: .gameDate)
        if let steps = steps { try values.encode(steps, forKey: .steps) }
        else { try values.encodeNil(forKey: .steps) }
        try values.encodeIfPresent(walkingRunningDistanceMetres, forKey: .walkingRunningDistanceMetres)
        try values.encodeIfPresent(activeEnergyKcal, forKey: .activeEnergyKcal)
        try values.encodeIfPresent(flightsClimbed, forKey: .flightsClimbed)
    }
}

struct ActivityEnrolmentRequest: Codable {
    let requestId: UUID
    let installationId: UUID
    let observedAt: Date
    let expectedDeviceId: UUID?
    let steps: Int64?
    var walkingRunningDistanceMetres: String? = nil
    var activeEnergyKcal: String? = nil
    var flightsClimbed: Int64? = nil
    var workoutsAvailable: Bool? = nil
}

struct ActivitySyncRequest: Codable {
    let requestId: UUID
    let installationId: UUID
    let deviceId: UUID
    let observedAt: Date
    let days: [ActivityDayUpload]
    var workoutsAvailable: Bool? = nil
    var workouts: [WorkoutUpload]? = nil
}

struct APIActivityEnrolment: Codable {
    let requestId: UUID
    let device: APIActivityDevice
}

struct APIActivityDayResult: Codable {
    let gameDate: String
    let available: Bool
    let baselineEstablished: Bool
    let newlyEligibleSteps: Int64
    let waterSteps: Int64
    let creditedSteps: Int64
    let ruleVersion: String
    let activityCreditId: UUID?
}

struct APIActivitySyncResult: Codable {
    let requestId: UUID
    let acceptedAt: Date
    let device: APIActivityDevice
    let days: [APIActivityDayResult]
    let garden: APIGarden
    let activitySteps: String
    let firstMaturityCount: Int64
    let recapId: UUID?
}

struct APIRewardRecap: Codable, Identifiable {
    var id: UUID { recapId }
    let recapId: UUID
    let createdAt: Date
    let payload: Payload
    struct Payload: Codable {
        let kind: String
        let creditIds: [UUID]
        let plants: [Plant]
        let activityDays: [APIActivityDayResult]
        let resourceDeltas: [String: String]
    }
    struct Plant: Codable, Identifiable {
        var id: UUID { plantId }
        let plantId: UUID
        let beforeGrowthMicroUnits: String
        let afterGrowthMicroUnits: String
        let awardedGrowthMicroUnits: String
        let beforeStage: GrowthStage
        let afterStage: GrowthStage
        var skillBonusGrowthMicroUnits: String? = nil
    }
}

struct APIRewardRecaps: Codable {
    let recaps: [APIRewardRecap]
    let nextCursor: UUID?
}

struct APIRecapAcknowledgement: Codable {
    let requestId: UUID
    let recapId: UUID
    let acknowledgedAt: Date
}

struct RequestIdentity: Codable { let requestId: UUID }

struct RegisterAccountRequest: Codable {
    let requestId: UUID
    let username: String
    let displayName: String
    let gameTimezone: String
}

struct APIAccount: Codable {
    let profile: APIProfile
    let gardenId: UUID
    let starterPlantId: UUID
}
