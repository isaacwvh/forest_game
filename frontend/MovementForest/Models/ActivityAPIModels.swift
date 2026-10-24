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
        guard value.isFinite, value >= 0, value <= 1_000_000_000, value.rounded(.towardZero) == value else {
            throw ForestError.invalidData("Health returned a step quantity that cannot be uploaded as a whole count. Try reading again.")
        }
        return Int64(value)
    }
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
}

struct ActivityDayUpload: Codable, Equatable {
    let gameDate: String
    let steps: Int64?
    enum CodingKeys: String, CodingKey { case gameDate, steps }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(gameDate, forKey: .gameDate)
        if let steps = steps { try values.encode(steps, forKey: .steps) }
        else { try values.encodeNil(forKey: .steps) }
    }
}

struct ActivityEnrolmentRequest: Codable {
    let requestId: UUID
    let installationId: UUID
    let observedAt: Date
    let expectedDeviceId: UUID?
    let steps: Int64?
}

struct ActivitySyncRequest: Codable {
    let requestId: UUID
    let installationId: UUID
    let deviceId: UUID
    let observedAt: Date
    let days: [ActivityDayUpload]
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
