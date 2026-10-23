import Foundation

struct APIVisitorSession: Codable, Equatable {
    let sessionId: UUID
    let installationId: UUID
    let leaseExpiresAt: Date
}

struct APIVisitorOpportunity: Codable, Equatable, Identifiable {
    let opportunityId: UUID
    let sessionId: UUID
    let issuedAt: Date
    let expiresAt: Date
    let visualKey: String
    let tokens: String
    var id: UUID { opportunityId }
}

struct APIVisitorSource: Codable, Equatable {
    let plantId: UUID
    let stage: String
    let attractionMicroUnits: String
    let profile: APIProfileReference
}

struct APIVisitorSummary: Codable, Equatable {
    let gardenId: UUID
    let serverTime: Date
    let version: Int64
    let contextId: UUID
    let ruleVersion: String
    let isFixture: Bool
    let totalAttractionMicroUnits: String
    let sources: [APIVisitorSource]
    let storedVisitsMicroUnits: String
    let claimableVisits: String
    let capacity: Int
    let offlineVisitsPerHour: String
    let secondsUntilFull: Int?
    let tokenBalance: String
    let hostedActive: String
    let hostedOffline: String
    let hostedTotal: String
    let heartbeatSeconds: Int
    let session: APIVisitorSession?
    let opportunities: [APIVisitorOpportunity]
    var economyVersion: Int64? = nil
}

struct APIVisitorReward: Codable {
    let requestId: UUID
    let eventId: UUID?
    let visits: String
    let tokens: String
    let summary: APIVisitorSummary
}

struct VisitorMutationBody: Codable {
    let requestId: UUID
    let installationId: UUID?
}

struct PendingVisitorOperation: Codable, Equatable {
    enum Kind: String, Codable { case start, heartbeat, end, welcome, claim }
    let id: UUID
    let kind: Kind
    let target: UUID?
    let body: Data
    var path: String {
        switch kind {
        case .start: return "visitor-sessions"
        case .heartbeat: return "visitor-sessions/\(target!.uuidString)/heartbeat"
        case .end: return "visitor-sessions/\(target!.uuidString)/end"
        case .welcome: return "visitor-opportunities/\(target!.uuidString)/welcome"
        case .claim: return "stored-visits/claim"
        }
    }
    func validate() throws {
        let value = try ActivityWire.decoder().decode(VisitorMutationBody.self, from: body)
        let hasTarget = kind == .heartbeat || kind == .end || kind == .welcome
        let needsInstallation = kind == .start || kind == .heartbeat || kind == .end
        guard value.requestId == id, hasTarget == (target != nil), needsInstallation == (value.installationId != nil) else {
            throw ForestError.invalidData("The saved visitor request could not be verified.")
        }
    }
}

@MainActor
protocol VisitorServing {
    var serverID: String { get }
    func read() async throws -> APIVisitorSummary
    func mutate(_ operation: PendingVisitorOperation) async throws -> (APIVisitorSummary, APIVisitorReward?)
}

struct APIVisitorRepository: VisitorServing {
    let client: APIClient
    var serverID: String { client.baseURL.absoluteString }
    func read() async throws -> APIVisitorSummary { try await client.request("v1/me/visitors") }
    func mutate(_ operation: PendingVisitorOperation) async throws -> (APIVisitorSummary, APIVisitorReward?) {
        try operation.validate()
        if operation.kind == .welcome || operation.kind == .claim {
            let reward: APIVisitorReward = try await client.request("v1/me/" + operation.path, method: "POST", body: operation.body)
            return (reward.summary, reward)
        }
        let summary: APIVisitorSummary = try await client.request("v1/me/" + operation.path, method: "POST", body: operation.body)
        return (summary, nil)
    }
}

@MainActor
protocol VisitorJournalPersisting {
    func load(server: String, user: UUID) throws -> VisitorJournalState?
    func save(_ value: VisitorJournalState, server: String, user: UUID) throws
}

/// A tap made during a heartbeat is saved atomically with that heartbeat. Only
/// one reward can wait behind it; retries always retain the original UUID/body.
struct VisitorJournalState: Codable, Equatable {
    var pending: PendingVisitorOperation?
    var queuedReward: PendingVisitorOperation?

    init(pending: PendingVisitorOperation? = nil, queuedReward: PendingVisitorOperation? = nil) {
        self.pending = pending; self.queuedReward = queuedReward
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, pending, queuedReward, kind }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.kind) {
            // Read the original single-request journal without discarding it.
            pending = try PendingVisitorOperation(from: decoder); queuedReward = nil
        } else {
            guard try values.decode(Int.self, forKey: .formatVersion) == 2 else {
                throw ForestError.invalidData("Unsupported visitor journal format.")
            }
            pending = try values.decodeIfPresent(PendingVisitorOperation.self, forKey: .pending)
            queuedReward = try values.decodeIfPresent(PendingVisitorOperation.self, forKey: .queuedReward)
        }
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .formatVersion)
        try values.encodeIfPresent(pending, forKey: .pending)
        try values.encodeIfPresent(queuedReward, forKey: .queuedReward)
    }
    func validate() throws {
        try pending?.validate(); try queuedReward?.validate()
        if let reward = queuedReward {
            guard pending?.kind == .heartbeat, reward.id != pending?.id,
                  reward.kind == .welcome || reward.kind == .claim else {
                throw ForestError.invalidData("The queued visitor reward could not be verified.")
            }
        }
    }
}

struct VisitorJournalStore: VisitorJournalPersisting {
    var disk = AccountDiskStore()
    func load(server: String, user: UUID) throws -> VisitorJournalState? {
        let value = try disk.load(VisitorJournalState.self, kind: "visitor-request", server: server, user: user)
        try value?.validate()
        return value
    }
    func save(_ value: VisitorJournalState, server: String, user: UUID) throws {
        try value.validate()
        if value.pending != nil { try disk.save(value, kind: "visitor-request", server: server, user: user) }
        else { try disk.remove(kind: "visitor-request", server: server, user: user) }
    }
}
