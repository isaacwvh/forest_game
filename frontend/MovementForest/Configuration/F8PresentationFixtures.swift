#if DEBUG
import SwiftUI

/// Deterministic UI-test route. Never connects to an account or writes a journal.
@MainActor
private final class PackFixtureJournal: CollectionJournalPersisting {
    var state = CollectionJournalState()
    func load(server: String, user: UUID) throws -> CollectionJournalState? { state }
    func save(_ state: CollectionJournalState, server: String, user: UUID) throws { self.state = state }
}

private struct PackFixtureContract: Decodable {
    let summary: APICollectionSummary
    let catalogue: APICatalogue
    let exchange: APICollectionReceipt
    let opening: APICollectionReceipt
    let packs: APIPackPage
}

@MainActor
private struct PackFixtureService: CollectionServing {
    let contract: PackFixtureContract
    let rarity: String
    let serverID = "https://presentation-fixture.invalid"
    func summary() async throws -> APICollectionSummary { contract.summary }
    func catalogue() async throws -> APICatalogue { contract.catalogue }
    func packs(after: UUID?) async throws -> APIPackPage { contract.packs }
    func openings(after: UUID?) async throws -> APIOpeningPage { .init(openings: [], nextCursor: nil) }
    func definition(pack: String, version: Int) async throws -> APIPackDefinition {
        guard let definition = contract.summary.offers.first(where: { $0.pack.packId == pack && $0.pack.version == version })?.pack else {
            throw ForestError.invalidData("Fixture definition missing.")
        }
        return definition
    }
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt {
        guard operation.kind == .open else { throw ForestError.invalidData("Presentation fixture only opens packs.") }
        let result = contract.opening
        return APICollectionReceipt(requestId: operation.id, tokenBalance: result.tokenBalance, economyVersion: result.economyVersion,
            openingId: result.openingId, ownedPackId: operation.target, packId: result.packId, packVersion: result.packVersion,
            rarity: rarity, openedAt: result.openedAt, plant: result.plant)
    }
}

@MainActor
struct PackOpeningFixtureScreen: View {
    @State private var store: CollectionCoordinator?
    @State private var pack: APIOwnedPack?
    @State private var assets: BundleAssetCatalog?
    @State private var error: String?
    var body: some View {
        Group {
            if let store = store, let pack = pack, let assets = assets {
                PackOpeningScreen(store: store, pack: pack, assets: assets,
                                  reduceMotionOverride: ProcessInfo.processInfo.arguments.contains("--fixture-reduce-motion"))
            } else if let error = error { Text(error) }
            else { ProgressView("Loading presentation fixture…") }
        }.task {
            guard store == nil else { return }
            do {
                guard let url = Bundle.main.url(forResource: "collection-contract", withExtension: "json", subdirectory: "Fixtures") else {
                    throw ForestError.missingResource("collection fixture")
                }
                let contract = try ActivityWire.decoder().decode(PackFixtureContract.self, from: Data(contentsOf: url))
                let arguments = ProcessInfo.processInfo.arguments
                let rarity = ["rare", "epic", "legendary"].first { arguments.contains("--fixture-" + $0) } ?? "common"
                let coordinator = CollectionCoordinator(userID: UUID(), service: PackFixtureService(contract: contract, rarity: rarity),
                                                        journal: PackFixtureJournal())
                await coordinator.refresh()
                assets = try BundleAssetCatalog(); pack = contract.exchange.packs?.first; store = coordinator
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
