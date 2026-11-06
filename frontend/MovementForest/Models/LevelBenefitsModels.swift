import Foundation

struct APILevelBenefits: Codable, Equatable {
    let policyVersion: String
    let progressionVersion: Int64
    let gardenStateVersion: Int64
    let level: Int64
    let baseOfflineCapacity: Int
    let effectiveOfflineCapacity: Int
    let maximumOfflineCapacity: Int
    let plantLimit: Int
    let plantedLimit: Int
    let nextBaseIncrease: Int
    let nextPlantLevel: Int64?
    let nextPlantLimit: Int?

    func validate(progression: APIAccountProgression) throws {
        guard policyVersion == "level-benefits-v1", progressionVersion == progression.version,
              gardenStateVersion >= 0, level == progression.level,
              (600...1800).contains(baseOfflineCapacity), maximumOfflineCapacity == 3 * baseOfflineCapacity,
              (baseOfflineCapacity...maximumOfflineCapacity).contains(effectiveOfflineCapacity),
              (50...100).contains(plantLimit), (1...10000).contains(plantedLimit),
              (0...75).contains(nextBaseIncrease),
              (nextPlantLevel == nil) == (nextPlantLimit == nil),
              nextPlantLevel.map({ $0 > level && $0 <= 20 }) ?? true,
              nextPlantLimit.map({ $0 > plantLimit && $0 <= 100 }) ?? true else {
            throw ForestError.invalidData("Account capacity information could not be verified.")
        }
    }
}

struct APILevelUpNotice: Codable, Equatable, Identifiable {
    let id: UUID
    let policyVersion: String
    let fromLevel: Int64
    let toLevel: Int64
    let baseOfflineBefore: Int
    let baseOfflineAfter: Int
    let effectiveOfflineAfter: Int
    let plantLimitBefore: Int
    let plantLimitAfter: Int
    func validate() throws {
        guard policyVersion == "level-benefits-v1", fromLevel >= 1, toLevel > fromLevel,
              toLevel <= 100_000_000, (600...1800).contains(baseOfflineBefore),
              (baseOfflineBefore...1800).contains(baseOfflineAfter),
              (baseOfflineAfter...3 * baseOfflineAfter).contains(effectiveOfflineAfter),
              (50...100).contains(plantLimitBefore), (plantLimitBefore...100).contains(plantLimitAfter) else {
            throw ForestError.invalidData("The level-up could not be verified.")
        }
    }
}

struct APILevelUpClaim: Codable {
    let notice: APILevelUpNotice
    let mayPresent: Bool
}

@MainActor
protocol LevelUpServing {
    func claim(notice: UUID, request: UUID, installation: UUID) async throws -> APILevelUpClaim
}

struct APILevelUpRepository: LevelUpServing {
    let client: APIClient
    private struct Body: Encodable { let requestId: UUID; let installationId: UUID }
    func claim(notice: UUID, request: UUID, installation: UUID) async throws -> APILevelUpClaim {
        try await client.request("v1/me/level-up-notices/\(notice.uuidString)/present", method: "POST",
            body: ActivityWire.encoder().encode(Body(requestId: request, installationId: installation)))
    }
}
