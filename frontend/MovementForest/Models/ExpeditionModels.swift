import Foundation

struct ExpeditionReward: Codable, Equatable {
    var tokens: Int? = nil
    var gems: Int? = nil
    var itemId: String? = nil
    var packId: String? = nil
    var version: Int? = nil
    var accessibilityName: String {
        if let tokens = tokens { return "\(tokens) tokens" }
        if let gems = gems { return "\(gems) gems" }
        if packId != nil { return "1 Standard Woodland pack" }
        switch itemId {
        case "astronomers-satchel": return "1 Astronomer's Forgotten Satchel"
        case "comet-basin": return "1 Comet-Catcher's Basin"
        case "worldseed-orrery": return "1 Worldseed Orrery"
        default: return "Reward unavailable"
        }
    }
    var quantity: String { String(tokens ?? gems ?? 1) }
}
struct ExpeditionEntitlement: Codable, Equatable, Identifiable {
    let id: UUID
    let rewardKey: String
    let reward: ExpeditionReward
    var claimed: Bool
}
struct ExpeditionQuest: Codable, Equatable, Identifiable {
    let id: String
    let piece: Int
    let description: String
    let target: Int
    let reward: ExpeditionReward
    let current: Int
    let completedAt: Date?
    var entitlement: ExpeditionEntitlement?
    var claimed: Bool { entitlement?.claimed == true }
}
struct ExpeditionCoverage: Codable, Equatable {
    let gameDate: String
    let startsAt: Date
    let through: Date
    let stepsNeeded: Bool
    let workoutsNeeded: Bool
}
struct ExpeditionRun: Codable, Equatable, Identifiable {
    var id: UUID { runId }
    let runId: UUID
    let month: String
    let templateVersion: String
    let name: String
    let timezone: String
    let serverNow: Date
    let startsAt: Date
    let endsAt: Date
    let evidenceUntil: Date
    let progressVersion: Int64
    let completedCount: Int
    let artworkKey: String
    var quests: [ExpeditionQuest]
    var rewards: [ExpeditionEntitlement]
    let coverage: [ExpeditionCoverage]
    func confirmingClaims(_ identifiers: Set<UUID>) -> Self {
        var copy = self
        for index in copy.rewards.indices where identifiers.contains(copy.rewards[index].id) {
            copy.rewards[index].claimed = true
        }
        for index in copy.quests.indices {
            if let id = copy.quests[index].entitlement?.id, identifiers.contains(id) {
                copy.quests[index].entitlement?.claimed = true
            }
        }
        return copy
    }
    func validated() throws -> Self {
        guard timezone == "UTC", startsAt < endsAt, endsAt < evidenceUntil,
              progressVersion >= 0, quests.count == 9, Set(quests.map(\.id)).count == 9,
              Set(quests.map(\.piece)) == Set(0..<9),
              quests.allSatisfy({ $0.target > 0 && (0...$0.target).contains($0.current) &&
                  ($0.completedAt == nil || $0.current == $0.target) &&
                  (!$0.claimed || $0.completedAt != nil) }),
              completedCount == quests.filter({ $0.completedAt != nil }).count,
              Set(rewards.map(\.id)).count == rewards.count,
              rewards.count <= 11,
              quests.allSatisfy({ quest in
                  guard let entitlement = quest.entitlement else { return !quest.claimed }
                  return quest.completedAt != nil && entitlement.rewardKey == "quest:" + quest.id &&
                      entitlement.reward == quest.reward && rewards.contains(entitlement)
              }),
              coverage.count <= 31, coverage.allSatisfy({ $0.startsAt >= startsAt && $0.through <= endsAt && $0.startsAt < $0.through }) else {
            throw ForestError.invalidData("The expedition response could not be verified.")
        }
        return self
    }
}
struct ExpeditionStatus: Codable {
    let serverNow: Date
    var current: ExpeditionRun?
    var previous: [ExpeditionRun]
}
struct ExpeditionArchive: Codable {
    let runs: [ExpeditionRun]
    let nextCursor: UUID?
}
struct ExpeditionEvidenceDay: Codable {
    let gameDate: String
    let startsAt: Date
    let through: Date
    var steps: Int64?
    var workoutsComplete: Bool
}
struct ExpeditionEvidenceBody: Codable {
    let schemaVersion: Int
    let requestId: UUID
    let deviceId: UUID
    let installationId: UUID
    let observedAt: Date
    let days: [ExpeditionEvidenceDay]
    let workouts: [WorkoutUpload]
}
struct ExpeditionEvidenceResult: Decodable {
    let requestId: UUID
    let runId: UUID
    let progressVersion: Int64
    let acceptedAt: Date
}
struct ExpeditionHealthEvidence {
    var days: [ExpeditionEvidenceDay]
    var workouts: [WorkoutUpload]
}
struct PendingExpeditionEvidence: Codable {
    let id: UUID
    let runID: UUID
    let body: Data
}
struct ExpeditionJournal: Codable {
    var status: ExpeditionStatus?
    var confirmedAt: Date?
    var operations: [PendingExpeditionEvidence] = []
    var claimedEntitlements: [UUID]? = nil
}
