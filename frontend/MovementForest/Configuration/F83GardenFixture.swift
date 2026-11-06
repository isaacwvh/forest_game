#if DEBUG
import Foundation

/// Explicit UI-test input. No authentication, network, Health upload or disk journal.
struct PresentationGardenContract: Decodable {
    let profile: APIProfile
    let catalogue: APICatalogue
    let emptyGarden: APIGarden
    let inventory: APIInventory
}

final class PresentationEditJournal: PendingEditPersisting {
    private var edit: PendingGardenEdit?
    func load(server: String, user: UUID) throws -> PendingGardenEdit? { edit }
    func save(_ edit: PendingGardenEdit) throws { self.edit = edit }
    func remove(server: String, user: UUID) throws { edit = nil }
}

@MainActor
private struct PresentationAccountService: AccountSummaryServing {
    let serverID = "https://account-presentation-fixture.invalid"
    let value: APIAccountSummary
    let offline: Bool
    func accountSummary() async throws -> APIAccountSummary {
        if offline { throw URLError(.notConnectedToInternet) }
        return value
    }
}

@MainActor
private final class PresentationAccountCache: AccountSummaryPersisting {
    var value: AccountSummaryCache?
    init(_ snapshot: APIAccountSummary?) {
        value = snapshot.map { AccountSummaryCache(snapshot: $0, confirmedAt: $0.serverTime) }
    }
    func load(server: String, user: UUID) throws -> AccountSummaryCache? { value }
    func save(_ value: AccountSummaryCache, server: String, user: UUID) throws { self.value = value }
}

@MainActor
enum PresentationAccountFixture {
    static func store(profile: APIProfile) throws -> AccountSummaryStore {
        guard let url = Bundle.main.url(forResource: "account-summary-contract", withExtension: "json", subdirectory: "Fixtures") else {
            throw ForestError.missingResource("account-summary-contract")
        }
        let values = try ActivityWire.decoder().decode([String: APIAccountSummary].self, from: Data(contentsOf: url))
        let arguments = ProcessInfo.processInfo.arguments
        guard let source = values[arguments.contains("--fixture-account-fresh") ? "fresh" : "grown"] else {
            throw ForestError.invalidData("Account presentation fixture is missing.")
        }
        let identity = APIAccountIdentity(userId: profile.userId, username: profile.username, displayName: profile.displayName,
            gameTimezone: profile.gameTimezone, createdAt: source.profile.createdAt)
        let value = try APIAccountSummary(serverTime: source.serverTime, profile: identity,
            progression: source.progression, wallet: source.wallet).validated(user: profile.userId)
        let offline = arguments.contains("--fixture-account-offline") || arguments.contains("--fixture-account-failed")
        return AccountSummaryStore(userID: profile.userId,
            service: PresentationAccountService(value: value, offline: offline),
            cache: PresentationAccountCache(arguments.contains("--fixture-account-offline") ? value : nil))
    }
}

@MainActor
final class PresentationGardenService: GardenServing {
    let serverID = "https://garden-presentation-fixture.invalid"
    private let contract: PresentationGardenContract
    private var current: APIGarden
    private var copies: [APIOwnedPlant]
    private var receipts: [UUID: GardenEditResult] = [:]
    init() throws {
        guard let url = Bundle.main.url(forResource: "editor-contract", withExtension: "json", subdirectory: "Fixtures") else {
            throw ForestError.missingResource("editor-contract")
        }
        contract = try ActivityWire.decoder().decode(PresentationGardenContract.self, from: Data(contentsOf: url))
        current = contract.emptyGarden; copies = contract.inventory.plants
    }
    func profile() async throws -> APIProfile { contract.profile }
    func catalogue() async throws -> APICatalogue { contract.catalogue }
    func garden() async throws -> APIGarden { current }
    func inventory(after: UUID?) async throws -> APIInventory { APIInventory(plants: copies.filter { $0.placement == nil }, nextCursor: nil) }
    func edit(body: Data) async throws -> GardenEditResult {
        let request = try ActivityWire.decoder().decode(GardenEditRequest.self, from: body)
        if let receipt = receipts[request.requestId] { return receipt }
        guard request.expectedLayoutVersion == current.layoutVersion, let action = request.actions.first,
              let index = copies.firstIndex(where: { $0.id == action.plantId }) else { throw ForestError.invalidData("Invalid fixture edit.") }
        let copy = copies[index]
        let placement: APIPlacement? = action.action == .store ? nil : APIPlacement(gardenId: current.gardenId,
            x: action.x ?? copy.placement?.x ?? 0, y: action.y ?? copy.placement?.y ?? 0,
            rotationDegrees: action.rotationDegrees ?? copy.placement?.rotationDegrees ?? 0)
        let updated = APIOwnedPlant(plantId: copy.id, speciesId: copy.speciesId, variantId: copy.variantId,
            growthMicroUnits: copy.growthMicroUnits, growthStage: copy.growthStage, modelKey: copy.modelKey,
            thumbnailKey: copy.thumbnailKey, placement: placement, pinnedProfiles: copy.pinnedProfiles,
            growthProgress: copy.growthProgress, baseAttractionMicroUnits: copy.baseAttractionMicroUnits,
            contributesAttraction: copy.contributesAttraction, gardenSkills: copy.gardenSkills)
        copies[index] = updated
        current = APIGarden(gardenId: current.gardenId, width: current.width, depth: current.depth,
            coordinateUnit: current.coordinateUnit, gardenUnitMetres: current.gardenUnitMetres,
            catalogVersion: current.catalogVersion, layoutVersion: current.layoutVersion + 1,
            stateVersion: current.stateVersion + 1, plants: copies.filter { $0.placement != nil })
        let receipt = GardenEditResult(requestId: request.requestId, garden: current, updatedPlants: [updated])
        receipts[request.requestId] = receipt; return receipt
    }
}
#endif
