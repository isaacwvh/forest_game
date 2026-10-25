import Foundation

struct APIPackOutcome: Codable, Equatable, Identifiable {
    let speciesId: String
    let variantId: String
    let profiles: APIPinnedProfiles
    var id: String { speciesId + "/" + variantId }
}

struct APIRarityPool: Codable, Equatable, Identifiable {
    let rarity: String
    let weight: Int
    var outcomes: [APIPackOutcome]? = nil
    var species: [APIPackSpecies]? = nil
    var id: String { rarity }
}

struct APIPackVariant: Codable, Equatable, Identifiable {
    let variantId: String
    let weight: Int
    let profiles: APIPinnedProfiles
    var id: String { variantId }
}

struct APIPackSpecies: Codable, Equatable, Identifiable {
    let speciesId: String
    let variants: [APIPackVariant]
    var id: String { speciesId }
}

struct VariantDrawOdds: Identifiable {
    let variantId: String
    let conditional: Double
    let overall: Double
    var id: String { variantId }
}

struct SpeciesDrawOdds: Identifiable {
    let speciesId: String
    let rarity: String
    let withinRarity: Double
    let overall: Double
    let variants: [VariantDrawOdds]
    var id: String { rarity + "/" + speciesId }
}

struct APIPackDefinition: Codable, Equatable, Identifiable {
    let packId: String
    let version: Int
    let isFixture: Bool
    let displayName: String
    let description: String
    let rarities: [APIRarityPool]
    let totalWeight: Int
    var schemaVersion: Int? = nil // Cached/legacy definitions predate explicit native decoding.
    var id: String { "\(packId)/\(version)" }
    func probability(_ pool: APIRarityPool, perPlant: Bool = false) -> String {
        let count = pool.outcomes?.count ?? 0
        guard totalWeight > 0, !perPlant || count > 0 else { return "Unavailable" }
        let denominator = Double(totalWeight) * (perPlant ? Double(count) : 1)
        return (Double(pool.weight) / denominator).formatted(.percent.precision(.fractionLength(0...4)))
    }

    var speciesOdds: [SpeciesDrawOdds] {
        guard totalWeight > 0 else { return [] }
        return rarities.flatMap { pool -> [SpeciesDrawOdds] in
            let rarityChance = Double(pool.weight) / Double(totalWeight)
            if schemaVersion == 2 {
                let species = pool.species ?? []
                guard !species.isEmpty else { return [] }
                return species.map { plant in
                    let total = plant.variants.reduce(0) { $0 + $1.weight }
                    let chance = 1 / Double(species.count)
                    return SpeciesDrawOdds(speciesId: plant.speciesId, rarity: pool.rarity,
                        withinRarity: chance, overall: rarityChance * chance,
                        variants: plant.variants.map { variant in
                            let conditional = total > 0 ? Double(variant.weight) / Double(total) : 0
                            return VariantDrawOdds(variantId: variant.variantId, conditional: conditional,
                                                   overall: rarityChance * chance * conditional)
                        })
                }
            }
            guard schemaVersion == nil || schemaVersion == 1 else { return [] }
            let outcomes = pool.outcomes ?? []
            let groups = Dictionary(grouping: outcomes, by: \.speciesId)
            guard !outcomes.isEmpty else { return [] }
            return groups.keys.sorted().map { speciesId in
                let variants = groups[speciesId] ?? []
                let chance = Double(variants.count) / Double(outcomes.count)
                return SpeciesDrawOdds(speciesId: speciesId, rarity: pool.rarity,
                    withinRarity: chance, overall: rarityChance * chance,
                    variants: variants.map { variant in
                        VariantDrawOdds(variantId: variant.variantId, conditional: 1 / Double(variants.count),
                                        overall: rarityChance / Double(outcomes.count))
                    })
            }
        }
    }
}

struct APIExchangeOffer: Codable, Identifiable {
    let offerId: String
    let offerVersion: Int
    let tokenCost: String
    let pack: APIPackDefinition
    var id: String { "\(offerId)/\(offerVersion)" }
}

struct APICollectionSummary: Codable {
    let tokenBalance: String
    let economyVersion: Int64
    let offers: [APIExchangeOffer]
    var milestones: [APIIntroMilestone]? = nil
}

struct APIIntroMilestone: Codable, Identifiable {
    let milestoneId: String
    let title: String
    let description: String
    let rewardTokens: String
    let eligible: Bool
    let claimed: Bool
    var id: String { milestoneId }
}

struct APIOwnedPack: Codable, Identifiable {
    let ownedPackId: UUID
    let packId: String
    let version: Int
    let acquiredAt: Date
    var id: UUID { ownedPackId }
    var definitionID: String { "\(packId)/\(version)" }
}

struct APIPackPage: Codable { let packs: [APIOwnedPack]; let nextCursor: UUID? }
struct APIOpeningPage: Codable { let openings: [APICollectionReceipt]; let nextCursor: UUID? }

/// Both operations share accounting fields; the selected operation validates its result.
struct APICollectionReceipt: Codable, Identifiable {
    let requestId: UUID
    let tokenBalance: String
    let economyVersion: Int64
    var exchangeId: UUID? = nil
    var quantity: Int? = nil
    var tokensSpent: String? = nil
    var packs: [APIOwnedPack]? = nil
    var openingId: UUID? = nil
    var ownedPackId: UUID? = nil
    var packId: String? = nil
    var packVersion: Int? = nil
    var rarity: String? = nil
    var openedAt: Date? = nil
    var plant: APIOwnedPlant? = nil
    var milestoneId: String? = nil
    var milestoneEventId: UUID? = nil
    var tokensEarned: String? = nil
    var id: UUID { openingId ?? exchangeId ?? requestId }
}

struct CollectionExchangeBody: Codable {
    let requestId: UUID
    let offerId: String
    let offerVersion: Int
    let quantity: Int
}

struct CollectionOpenBody: Codable { let requestId: UUID }

struct PendingCollectionOperation: Codable, Equatable {
    enum Kind: String, Codable { case exchange, open, milestone }
    let id: UUID
    let kind: Kind
    let target: UUID?
    let body: Data
    var milestoneID: String? = nil
    func validate() throws {
        switch kind {
        case .milestone:
            let request = try ActivityWire.decoder().decode(CollectionOpenBody.self, from: body)
            guard request.requestId == id, target == nil,
                  let milestoneID = milestoneID,
                  milestoneID.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                throw ForestError.invalidData("The saved milestone claim could not be verified.")
            }
        case .exchange:
            let request = try ActivityWire.decoder().decode(CollectionExchangeBody.self, from: body)
            guard request.requestId == id, target == nil, (1...20).contains(request.quantity),
                  request.offerVersion > 0, request.offerId.range(of: "^[a-z][a-z0-9_-]{0,99}$", options: .regularExpression) != nil else {
                throw ForestError.invalidData("The saved exchange could not be verified.")
            }
        case .open:
            let request = try ActivityWire.decoder().decode(CollectionOpenBody.self, from: body)
            guard request.requestId == id, target != nil else {
                throw ForestError.invalidData("The saved pack opening could not be verified.")
            }
        }
    }
}

struct CollectionJournalState: Codable {
    var pending: PendingCollectionOperation? = nil
    var result: APICollectionReceipt? = nil
}

@MainActor
protocol CollectionServing {
    var serverID: String { get }
    func summary() async throws -> APICollectionSummary
    func catalogue() async throws -> APICatalogue
    func packs(after: UUID?) async throws -> APIPackPage
    func openings(after: UUID?) async throws -> APIOpeningPage
    func definition(pack: String, version: Int) async throws -> APIPackDefinition
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt
}

struct APICollectionRepository: CollectionServing {
    let client: APIClient
    var serverID: String { client.baseURL.absoluteString }
    func summary() async throws -> APICollectionSummary { try await client.request("v1/me/collection") }
    func catalogue() async throws -> APICatalogue { try await client.request("v1/catalog") }
    private func query(_ cursor: UUID?) -> [URLQueryItem] {
        var result = [URLQueryItem(name: "limit", value: "30")]
        if let cursor = cursor { result.append(URLQueryItem(name: "after", value: cursor.uuidString)) }
        return result
    }
    func packs(after: UUID?) async throws -> APIPackPage { try await client.request("v1/me/packs", query: query(after)) }
    func openings(after: UUID?) async throws -> APIOpeningPage { try await client.request("v1/me/pack-openings", query: query(after)) }
    func definition(pack: String, version: Int) async throws -> APIPackDefinition {
        guard pack.range(of: "^[a-z][a-z0-9_-]{0,99}$", options: .regularExpression) != nil, version > 0 else {
            throw ForestError.invalidData("The pack identifier is invalid.")
        }
        return try await client.request("v1/pack-definitions/\(pack)/versions/\(version)")
    }
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt {
        try operation.validate()
        let path: String
        switch operation.kind {
        case .exchange: path = "v1/me/exchanges"
        case .open: path = "v1/me/packs/\(operation.target!.uuidString)/open"
        case .milestone: path = "v1/me/milestones/\(operation.milestoneID!)/claim"
        }
        return try await client.request(path, method: "POST", body: operation.body)
    }
}
