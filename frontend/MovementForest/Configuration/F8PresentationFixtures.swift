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
private final class PackFixtureService: CollectionServing {
    let contract: PackFixtureContract
    let rarity: String
    private(set) var openingCount = 0
    init(contract: PackFixtureContract, rarity: String) { self.contract = contract; self.rarity = rarity }
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
        openingCount += 1
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
    @State private var service: PackFixtureService?
    var body: some View {
        Group {
            if let store = store, let pack = pack, let assets = assets, let service = service {
                PackFixtureHost(store: store, service: service, pack: pack, assets: assets)
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
                let service = PackFixtureService(contract: contract, rarity: rarity)
                let coordinator = CollectionCoordinator(userID: UUID(), service: service,
                                                        journal: PackFixtureJournal())
                await coordinator.refresh()
                assets = try BundleAssetCatalog()
                if let original = contract.exchange.packs?.first, arguments.contains("--fixture-generic-pack") {
                    pack = APIOwnedPack(ownedPackId: original.id, packId: "generic", version: original.version,
                                        acquiredAt: original.acquiredAt)
                } else { pack = contract.exchange.packs?.first }
                self.service = service; store = coordinator
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
private struct PackFixtureHost: View {
    @ObservedObject var store: CollectionCoordinator
    let service: PackFixtureService
    let pack: APIOwnedPack
    let assets: BundleAssetCatalog
    @State private var showing = true
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let result = store.confirmedOpening(for: pack.id), let plant = result.plant {
                    Text("Saved opening").accessibilityIdentifier("fixture.savedOpening")
                    PlantNameText(plant.speciesId.capitalized, rarity: result.rarity)
                    Button("View saved result") { showing = true }.accessibilityIdentifier("fixture.viewResult")
                }
                Text("Opening requests: \(service.openingCount)")
                    .accessibilityValue(String(service.openingCount)).accessibilityIdentifier("fixture.openingCount")
            }.navigationTitle("Packs")
        }.fullScreenCover(isPresented: $showing) {
            PackOpeningScreen(store: store, pack: pack, assets: assets,
                reduceMotionOverride: ProcessInfo.processInfo.arguments.contains("--fixture-reduce-motion"))
        }
    }
}
/// Exercises the actual collection views without network, authentication or disk writes.
@MainActor
private final class CleanupCollectionService: ObservableObject, CollectionServing {
    let serverID = "https://collection-cleanup-fixture.invalid"
    let contract: PackFixtureContract
    @Published private(set) var requestCount = 0
    private var balance: Decimal
    private var version: Int64
    private var unopened: [APIOwnedPack]
    private var history: [APICollectionReceipt]
    private var receipts: [UUID: APICollectionReceipt] = [:]

    init(contract: PackFixtureContract) throws {
        self.contract = contract
        guard let balance = ExactAmount.integer(contract.summary.tokenBalance) else {
            throw ForestError.invalidData("Invalid fixture balance.")
        }
        self.balance = balance; version = max(contract.summary.economyVersion, contract.opening.economyVersion)
        unopened = contract.packs.packs; history = [contract.opening]
    }
    func summary() async throws -> APICollectionSummary {
        APICollectionSummary(tokenBalance: NSDecimalNumber(decimal: balance).stringValue,
                             economyVersion: version, offers: contract.summary.offers)
    }
    func catalogue() async throws -> APICatalogue { contract.catalogue }
    func packs(after: UUID?) async throws -> APIPackPage { .init(packs: unopened, nextCursor: nil) }
    func openings(after: UUID?) async throws -> APIOpeningPage { .init(openings: history, nextCursor: nil) }
    func definition(pack: String, version: Int) async throws -> APIPackDefinition {
        guard let value = contract.summary.offers.first(where: { $0.pack.packId == pack && $0.pack.version == version }) else {
            throw ForestError.invalidData("Missing fixture pack.")
        }
        return value.pack
    }
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt {
        try operation.validate()
        if let receipt = receipts[operation.id] { return receipt }
        let receipt: APICollectionReceipt
        switch operation.kind {
        case .exchange:
            let body = try ActivityWire.decoder().decode(CollectionExchangeBody.self, from: operation.body)
            guard let offer = contract.summary.offers.first(where: { $0.offerId == body.offerId && $0.offerVersion == body.offerVersion }),
                  let cost = ExactAmount.integer(offer.tokenCost), balance >= cost * Decimal(body.quantity) else {
                throw ForestError.invalidData("Invalid fixture purchase.")
            }
            let packs = (0..<body.quantity).map { _ in
                APIOwnedPack(ownedPackId: UUID(), packId: offer.pack.packId, version: offer.pack.version, acquiredAt: Date())
            }
            balance -= cost * Decimal(body.quantity); version += 1; unopened += packs
            receipt = APICollectionReceipt(requestId: operation.id, tokenBalance: NSDecimalNumber(decimal: balance).stringValue,
                economyVersion: version, exchangeId: UUID(), quantity: body.quantity,
                tokensSpent: NSDecimalNumber(decimal: cost * Decimal(body.quantity)).stringValue, packs: packs)
        case .open:
            guard let index = unopened.firstIndex(where: { $0.id == operation.target }) else {
                throw ForestError.invalidData("Fixture pack already opened.")
            }
            let pack = unopened.remove(at: index); version += 1
            receipt = APICollectionReceipt(requestId: operation.id, tokenBalance: NSDecimalNumber(decimal: balance).stringValue,
                economyVersion: version, openingId: UUID(), ownedPackId: pack.id, packId: pack.packId,
                packVersion: pack.version, rarity: contract.opening.rarity, openedAt: Date(), plant: contract.opening.plant)
            history.insert(receipt, at: 0)
        case .milestone:
            throw ForestError.invalidData("Milestones are outside this presentation fixture.")
        }
        receipts[operation.id] = receipt; requestCount += 1
        return receipt
    }
}

@MainActor
struct CollectionCleanupFixtureScreen: View {
    @State private var store: CollectionCoordinator?
    @State private var service: CleanupCollectionService?
    @State private var assets: BundleAssetCatalog?
    @State private var error: String?
    var body: some View {
        Group {
            if let store = store, let service = service, let assets = assets {
                CollectionCleanupFixtureHost(store: store, service: service, assets: assets)
            } else if let error = error { Text(error) }
            else { ProgressView("Loading collection fixture…") }
        }.task {
            guard store == nil else { return }
            do {
                guard let url = Bundle.main.url(forResource: "collection-contract", withExtension: "json", subdirectory: "Fixtures") else {
                    throw ForestError.missingResource("collection fixture")
                }
                let contract = try ActivityWire.decoder().decode(PackFixtureContract.self, from: Data(contentsOf: url))
                let service = try CleanupCollectionService(contract: contract)
                let store = CollectionCoordinator(userID: UUID(), service: service, journal: PackFixtureJournal())
                await store.refresh()
                assets = try BundleAssetCatalog(); self.service = service; self.store = store
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
private struct CollectionCleanupFixtureHost: View {
    @ObservedObject var store: CollectionCoordinator
    @ObservedObject var service: CleanupCollectionService
    let assets: BundleAssetCatalog
    @State private var destination = CollectionDestination.exchange
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Page", selection: $destination) {
                    Text("Exchange").tag(CollectionDestination.exchange)
                    Text("Packs").tag(CollectionDestination.draws)
                }.pickerStyle(.segmented)
                CollectionScreen(store: store, destination: destination, assets: assets,
                                 navigate: { destination = $0 ?? .draws })
                HStack {
                    Text("Requests: \(service.requestCount)").accessibilityValue(String(service.requestCount))
                        .accessibilityIdentifier("fixture.collectionRequests")
                    Text("Packs: \(store.packs.count)").accessibilityValue(String(store.packs.count))
                        .accessibilityIdentifier("fixture.collectionPacks")
                    Text("Tokens: \(store.tokenBalance ?? "Unavailable")").accessibilityValue(store.tokenBalance ?? "Unavailable")
                        .accessibilityIdentifier("fixture.collectionTokens")
                }.font(.caption)
            }.navigationTitle(destination.rawValue)
        }
    }
}
#endif
