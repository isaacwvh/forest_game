import Foundation

struct APIAccountIdentity: Codable, Equatable {
    let userId: UUID
    let username: String
    let displayName: String
    let gameTimezone: String
    let createdAt: Date
}

struct APIAccountProgression: Codable, Equatable {
    let rulesVersion: String
    let version: Int64
    let lifetimeRecordedSteps: String
    let stepXp: String
    let totalXp: String
    let level: Int64
    let xpIntoLevel: String
    let xpForNextLevel: String
    let stepsIntoNextGem: Int64
    let stepsPerGem: Int64
    let stepsToNextGem: Int64
    let plantsGrownToAdulthood: String
    let lastSyncAt: Date?
}

struct APIAccountWallet: Codable, Equatable {
    let economyVersion: Int64
    let tokenBalance: String
    let gemBalance: String
    let lifetimeGemsEarned: String
    let initialized: Bool
    let hostedActive: String
    let hostedOffline: String
    let hostedTotal: String
}

struct APIAccountSummary: Codable, Equatable {
    let serverTime: Date
    let profile: APIAccountIdentity
    var progression: APIAccountProgression
    var wallet: APIAccountWallet
    var benefits: APILevelBenefits? = nil
    var levelUpNotice: APILevelUpNotice? = nil

    static func amount(_ text: String) -> Int64? {
        guard let value = Int64(text), value >= 0, String(value) == text else { return nil }
        return value
    }

    func validated(user: UUID) throws -> Self {
        let p = progression, w = wallet
        guard profile.userId == user, !profile.username.isEmpty, !profile.displayName.isEmpty,
              TimeZone(identifier: profile.gameTimezone) != nil,
              p.rulesVersion == "step-progression-v1", p.version >= 0, w.economyVersion >= 0,
              (1...100_000_000).contains(p.level), p.stepsPerGem == 10_000,
              let steps = Self.amount(p.lifetimeRecordedSteps),
              let xp = Self.amount(p.totalXp), let stepXP = Self.amount(p.stepXp),
              let into = Self.amount(p.xpIntoLevel), let needed = Self.amount(p.xpForNextLevel),
              Self.amount(p.plantsGrownToAdulthood) != nil,
              Self.amount(w.tokenBalance) != nil,
              let gems = Self.amount(w.gemBalance), let earned = Self.amount(w.lifetimeGemsEarned),
              let active = Self.amount(w.hostedActive), let offline = Self.amount(w.hostedOffline),
              let total = Self.amount(w.hostedTotal), active <= Int64.max - offline,
              total == active + offline, gems <= earned else {
            throw ForestError.invalidData("The account summary could not be verified.")
        }
        // The level bound above keeps the arithmetic within Int64 even at the server's bigint limit.
        let n = p.level - 1
        let threshold = 25 * n * (n + 3) / 2
        guard stepXP == steps / 100, xp == stepXP, xp >= threshold,
              into == xp - threshold, needed == 50 + 25 * n, into < needed,
              p.stepsIntoNextGem == steps % 10_000,
              p.stepsToNextGem == 10_000 - p.stepsIntoNextGem,
              (w.initialized ? earned == steps / 10_000 : (earned == 0 && gems == 0)) else {
            throw ForestError.invalidData("Account progression could not be verified.")
        }
        try benefits?.validate(progression: p)
        try levelUpNotice?.validate()
        guard levelUpNotice.map({ $0.toLevel <= p.level }) ?? true else {
            throw ForestError.invalidData("The level-up is ahead of confirmed progress.")
        }
        return self
    }
}

struct AccountSummaryCache: Codable {
    let snapshot: APIAccountSummary
    let confirmedAt: Date
}

@MainActor
protocol AccountSummaryServing {
    var serverID: String { get }
    func accountSummary() async throws -> APIAccountSummary
}

struct APIAccountSummaryRepository: AccountSummaryServing {
    let client: APIClient
    var serverID: String { client.baseURL.absoluteString }
    func accountSummary() async throws -> APIAccountSummary {
        try await client.request("v1/me/account-summary")
    }
}

struct UnavailableAccountSummaryRepository: AccountSummaryServing {
    let serverID: String
    func accountSummary() async throws -> APIAccountSummary { throw URLError(.notConnectedToInternet) }
}
