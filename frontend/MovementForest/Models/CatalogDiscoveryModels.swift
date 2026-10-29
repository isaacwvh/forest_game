import Foundation

struct APICatalogDiscoveryEntry: Codable, Equatable {
    let speciesId: String
    let variantId: String
    let stages: [GrowthStage]
}

struct CatalogDiscoveryKey: Hashable {
    let species: String
    let variant: String
    let stage: GrowthStage
}

struct APICatalogDiscovery: Codable, Equatable {
    let userId: UUID
    let catalogVersion: String
    let discoveryVersion: Int64
    let entries: [APICatalogDiscoveryEntry]

    var keys: Set<CatalogDiscoveryKey> {
        Set(entries.flatMap { entry in
            entry.stages.map { CatalogDiscoveryKey(species: entry.speciesId, variant: entry.variantId, stage: $0) }
        })
    }

    func validated(user: UUID) throws -> Self {
        guard userId == user, discoveryVersion >= 0, !catalogVersion.isEmpty else {
            throw ForestError.invalidData("The catalog discovery response belongs to another account or is invalid.")
        }
        var variants = Set<CatalogDiscoveryKey>()
        for entry in entries {
            let identity = CatalogDiscoveryKey(species: entry.speciesId, variant: entry.variantId, stage: .sprout)
            guard !entry.speciesId.isEmpty, !entry.variantId.isEmpty,
                  variants.insert(identity).inserted, !entry.stages.isEmpty,
                  entry.stages == Array(GrowthStage.allCases.dropFirst().prefix(entry.stages.count)) else {
                throw ForestError.invalidData("The catalog discovery stages could not be verified.")
            }
        }
        return self
    }
}

struct CatalogDiscoveryCache: Codable {
    let snapshot: APICatalogDiscovery
    let confirmedAt: Date
}

@MainActor
protocol CatalogDiscoveryServing {
    var serverID: String { get }
    func discovery() async throws -> APICatalogDiscovery
}

struct APICatalogDiscoveryRepository: CatalogDiscoveryServing {
    let client: APIClient
    var serverID: String { client.baseURL.absoluteString }
    func discovery() async throws -> APICatalogDiscovery { try await client.request("v1/me/catalog-discovery") }
}

/// Offline/sample coordinators conceal later artwork until a real repository is attached.
struct UnavailableCatalogDiscoveryRepository: CatalogDiscoveryServing {
    let serverID: String
    func discovery() async throws -> APICatalogDiscovery { throw URLError(.notConnectedToInternet) }
}
