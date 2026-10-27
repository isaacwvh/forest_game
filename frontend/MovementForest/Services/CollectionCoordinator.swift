import Foundation
import Combine

@MainActor
protocol CollectionJournalPersisting {
    func load(server: String, user: UUID) throws -> CollectionJournalState?
    func save(_ state: CollectionJournalState, server: String, user: UUID) throws
}

struct CollectionJournalStore: CollectionJournalPersisting {
    let disk: AccountDiskStore
    init(disk: AccountDiskStore = AccountDiskStore()) { self.disk = disk }
    func load(server: String, user: UUID) throws -> CollectionJournalState? {
        let state = try disk.load(CollectionJournalState.self, kind: "collection", server: server, user: user)
        try state?.pending?.validate()
        return state
    }
    func save(_ state: CollectionJournalState, server: String, user: UUID) throws {
        try state.pending?.validate()
        try disk.save(state, kind: "collection", server: server, user: user)
    }
}

@MainActor
final class CollectionCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var offers: [APIExchangeOffer] = []
    @Published private(set) var milestones: [APIIntroMilestone] = []
    @Published private(set) var milestonesConfirmedAt: Date?
    @Published private(set) var refreshFailed = false
    @Published private(set) var confirmedMilestoneIDs: Set<String> = []
    @Published private(set) var packs: [APIOwnedPack] = []
    @Published private(set) var history: [APICollectionReceipt] = []
    @Published private(set) var catalogue: APICatalogue?
    @Published private(set) var definitions: [String: APIPackDefinition] = [:]
    @Published private(set) var tokenBalance: String?
    @Published private(set) var economyVersion: Int64 = -1
    @Published private(set) var busy = false
    @Published private(set) var recoveryLocked = false
    @Published private(set) var message: String?
    @Published private(set) var confirmedExchange: APICollectionReceipt?
    @Published private(set) var exchangeOfferID: String?
    @Published private(set) var exchangeMessage: String?
    @Published private(set) var state = CollectionJournalState()
    @Published private(set) var packCursor: UUID?
    @Published private(set) var historyCursor: UUID?
    private let userID: UUID
    private let service: any CollectionServing
    private let journal: any CollectionJournalPersisting
    private var attached = true
    var onWallet: ((String, Int64) -> Void)?
    var onPlantAwarded: (() async -> Void)?

    init(userID: UUID, service: any CollectionServing, journal: (any CollectionJournalPersisting)? = nil) {
        self.userID = userID; self.service = service
        let resolved = journal ?? CollectionJournalStore()
        self.journal = resolved
        do {
            state = try resolved.load(server: service.serverID, user: userID) ?? CollectionJournalState()
            try state.pending?.validate()
            if state.result?.exchangeId != nil { confirmedExchange = state.result }
            if let milestoneID = state.result?.milestoneId { confirmedMilestoneIDs.insert(milestoneID) }
        }
        catch { recoveryLocked = true; message = "The saved collection request needs attention. It has been retained." }
    }

    private var diagnosticScope: String { DiagnosticHistory.scope(server: service.serverID, user: userID) }
    private func displayFailure(_ error: Error) -> String {
        PlayerMessage.recordFailure("Collection", error, requestID: state.pending?.id.uuidString, scope: diagnosticScope)
        return PlayerMessage.failure(error, fallback: "The collection couldn’t update. Retry to recover any saved request.")
    }
    var canMutate: Bool { attached && !busy && !recoveryLocked && state.pending == nil && tokenBalance != nil }
    func canAfford(_ offer: APIExchangeOffer, quantity: Int) -> Bool {
        guard let balance = tokenBalance.flatMap(ExactAmount.integer), let cost = ExactAmount.integer(offer.tokenCost) else { return false }
        return (1...20).contains(quantity) && balance >= cost * Decimal(quantity)
    }
    func deactivate() { attached = false }
    func applyWallet(_ balance: String, version: Int64) {
        guard attached, version > economyVersion, ExactAmount.integer(balance) != nil else { return }
        tokenBalance = balance; economyVersion = version; onWallet?(balance, version)
    }
    private func persist(_ value: CollectionJournalState) throws {
        try journal.save(value, server: service.serverID, user: userID)
        state = value
    }
    private func recover() async throws {
        guard let pending = state.pending else { return }
        do {
            DiagnosticHistory.shared.record("Collection", "sending \(pending.kind.rawValue)", requestID: pending.id.uuidString, scope: diagnosticScope)
            let receipt = try await service.mutate(pending)
            guard attached else { return }
            let isOpening = pending.kind == .open
            let matchesOperation: Bool
            switch pending.kind {
            case .open: matchesOperation = receipt.ownedPackId == pending.target && receipt.plant != nil && receipt.openingId != nil
            case .exchange: matchesOperation = receipt.requestId == pending.id && receipt.exchangeId != nil && receipt.packs?.isEmpty == false
            case .milestone: matchesOperation = receipt.requestId == pending.id && receipt.milestoneId == pending.milestoneID && receipt.milestoneEventId != nil && receipt.tokensEarned != nil
            }
            guard receipt.economyVersion >= 0, ExactAmount.integer(receipt.tokenBalance) != nil,
                  matchesOperation else {
                throw ForestError.invalidData("The reward response could not be verified. Retry the saved request.")
            }
            // Persist the result and removal together. A disk failure retains the request.
            try persist(CollectionJournalState(pending: nil, result: receipt))
            if let milestoneID = receipt.milestoneId { confirmedMilestoneIDs.insert(milestoneID) }
            if pending.kind == .exchange {
                confirmedExchange = receipt
                exchangeOfferID = (try? ActivityWire.decoder().decode(CollectionExchangeBody.self, from: pending.body))?.offerId
                exchangeMessage = "Purchase confirmed. Your packs are saved."
            }
            applyWallet(receipt.tokenBalance, version: receipt.economyVersion)
            DiagnosticHistory.shared.record("Collection", "confirmed \(pending.kind.rawValue)", requestID: pending.id.uuidString, scope: diagnosticScope)
            message = pending.kind == .milestone ? "Milestone confirmed: +\(receipt.tokensEarned ?? "0") visitor tokens." :
                (isOpening ? "Your plant is in Storage." : "Your unopened packs are ready in Packs.")
            if isOpening { await onPlantAwarded?() }
        } catch let error as APIError where (400..<500).contains(error.status) &&
                    ![401, 408, 429].contains(error.status) && error.code != "idempotency_conflict" {
            guard attached else { return }
            try persist(CollectionJournalState(pending: nil, result: state.result))
            throw error
        }
    }
    private func loadCurrent() async throws {
        let summary = try await service.summary()
        guard attached else { return }
        applyWallet(summary.tokenBalance, version: summary.economyVersion)
        offers = summary.offers
        milestones = summary.milestones ?? []
        milestonesConfirmedAt = Date()
        for offer in offers { definitions[offer.pack.id] = offer.pack }
        let catalogue = try await service.catalogue()
        guard attached else { return }
        self.catalogue = catalogue
        let page = try await service.packs(after: nil)
        guard attached else { return }
        try await loadDefinitions(page.packs)
        guard attached else { return }
        packs = page.packs; packCursor = page.nextCursor
        let history = try await service.openings(after: nil)
        guard attached else { return }
        self.history = history.openings; historyCursor = history.nextCursor
    }
    private func loadDefinitions(_ packs: [APIOwnedPack]) async throws {
        for pack in packs where definitions[pack.definitionID] == nil {
            let definition = try await service.definition(pack: pack.packId, version: pack.version)
            guard attached else { return }
            definitions[definition.id] = definition
        }
    }
    func refresh() async {
        guard attached, !busy, !recoveryLocked else { return }
        busy = true; refreshFailed = false; message = nil; defer { busy = false }
        do { try await recover(); guard attached else { return }; try await loadCurrent() }
        catch { if attached {
            refreshFailed = true
            message = displayFailure(error)
            if state.pending?.kind == .exchange { exchangeMessage = "Purchase confirmation interrupted. Retry the saved request to recover its result." }
            else if exchangeOfferID != nil && confirmedExchange == nil { exchangeMessage = message }
        } }
    }
    private func submit(_ operation: PendingCollectionOperation) async {
        guard canMutate else { return }
        busy = true; refreshFailed = false; message = nil; defer { busy = false }
        do {
            try operation.validate()
            try persist(CollectionJournalState(pending: operation, result: state.result))
            try await recover()
            guard attached else { return }
            try await loadCurrent()
        } catch { if attached {
            refreshFailed = true
            message = displayFailure(error)
            if operation.kind == .exchange {
                if confirmedExchange?.requestId == operation.id {
                    exchangeMessage = "Purchase confirmed. Refresh the collection to update its list."
                } else {
                    exchangeMessage = state.pending == nil ? message : "Purchase confirmation interrupted. Retry the saved request to recover its result."
                }
            }
        } }
    }
    func exchange(_ offer: APIExchangeOffer, quantity: Int) async {
        guard canMutate, canAfford(offer, quantity: quantity) else { return }
        exchangeOfferID = offer.offerId; exchangeMessage = "Confirming purchase…"; confirmedExchange = nil
        let id = UUID()
        do {
            let body = try ActivityWire.encoder().encode(CollectionExchangeBody(requestId: id, offerId: offer.offerId,
                                                                               offerVersion: offer.offerVersion, quantity: quantity))
            await submit(PendingCollectionOperation(id: id, kind: .exchange, target: nil, body: body))
        } catch { message = displayFailure(error) }
    }
    func confirmedOpening(for packID: UUID) -> APICollectionReceipt? {
        ([state.result].compactMap { $0 } + history).first {
            $0.ownedPackId == packID && $0.openingId != nil && $0.plant != nil
        }
    }
    func open(_ pack: APIOwnedPack) async {
        guard attached, confirmedOpening(for: pack.id) == nil else { return }
        if let pending = state.pending {
            // A reopened/restarted presentation recovers the original operation.
            if pending.kind == .open && pending.target == pack.id { await refresh() }
            return
        }
        let id = UUID()
        do {
            let body = try ActivityWire.encoder().encode(CollectionOpenBody(requestId: id))
            await submit(PendingCollectionOperation(id: id, kind: .open, target: pack.id, body: body))
        } catch { message = displayFailure(error) }
    }
    func claim(_ milestone: APIIntroMilestone) async {
        guard canMutate, milestone.eligible, !milestone.claimed,
              !confirmedMilestoneIDs.contains(milestone.id) else { return }
        let id = UUID()
        do {
            let body = try ActivityWire.encoder().encode(CollectionOpenBody(requestId: id))
            await submit(PendingCollectionOperation(id: id, kind: .milestone, target: nil,
                                                     body: body, milestoneID: milestone.id))
        } catch { message = displayFailure(error) }
    }
    func dismissResult() {
        do { try persist(CollectionJournalState(pending: state.pending, result: nil)) }
        catch { message = "The result could not be dismissed. It is still saved." }
    }
    func loadMore(history: Bool = false) async {
        guard attached, !busy, !recoveryLocked else { return }
        busy = true; defer { busy = false }
        do {
            if history, let cursor = historyCursor {
                let page = try await service.openings(after: cursor)
                guard attached else { return }
                let ids = Set(self.history.map(\.id))
                self.history += page.openings.filter { !ids.contains($0.id) }; historyCursor = page.nextCursor
            } else if !history, let cursor = packCursor {
                let page = try await service.packs(after: cursor)
                guard attached else { return }
                try await loadDefinitions(page.packs)
                guard attached else { return }
                let ids = Set(packs.map(\.id))
                packs += page.packs.filter { !ids.contains($0.id) }; packCursor = page.nextCursor
            }
        } catch { if attached { message = displayFailure(error) } }
    }
}
