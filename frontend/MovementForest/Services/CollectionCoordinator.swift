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
    let discovery: CatalogDiscoveryStore
    @Published private(set) var offers: [APIExchangeOffer] = []
    @Published private(set) var itemOffers: [APIItemShopOffer] = []
    @Published private(set) var itemCapacity: APIItemCapacity?
    @Published private(set) var shop: APIShopRotation?
    @Published private(set) var shopRemaining: TimeInterval?
    private var shopCountdown: ShopCountdown?
    private var shopRefreshNeeded = false
    private var shopRetryAfter: TimeInterval = 0
    private let uptime: () -> TimeInterval
    @Published private(set) var capacity: APIInventoryCapacity?
    private var levelPlantLimit: Int?
    func applyLevelPlantLimit(_ limit: Int) {
        let confirmed = max(limit, capacity?.plantLimit ?? limit)
        guard confirmed > (levelPlantLimit ?? 0) else { return }
        levelPlantLimit = confirmed; capacity = capacity?.applyingPlantLimit(confirmed)
    }
    private func acceptCapacity(_ incoming: APIInventoryCapacity?) {
        if let known = levelPlantLimit, let incoming = incoming {
            levelPlantLimit = max(known, incoming.plantLimit)
        }
        capacity = incoming?.applyingPlantLimit(levelPlantLimit)
    }
    @Published private(set) var milestones: [APIIntroMilestone] = []
    @Published private(set) var milestonesConfirmedAt: Date?
    @Published private(set) var refreshFailed = false
    @Published private(set) var confirmedMilestoneIDs: Set<String> = []
    @Published private(set) var packs: [APIOwnedPack] = []
    @Published private(set) var history: [APICollectionReceipt] = []
    @Published private(set) var catalogue: APICatalogue?
    @Published private(set) var definitions: [String: APIPackDefinition] = [:]
    @Published private(set) var gemBalance: String?
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
    var onInventoryReceipt: ((APICollectionReceipt) async -> Void)?
    private var inventoryReconciliation: Task<Void, Never>?
    private var deferredRead: CollectionReadScope?
    private var refreshTask: Task<Void, Never>?
    private var refreshScope: CollectionReadScope?
    private var refreshedAt: [CollectionReadScope: TimeInterval] = [:]
    var unopenedPackCount: Int {
        capacity?.unopenedPacks ?? packs.filter { $0.id != state.result?.ownedPackId }.count
    }

    init(userID: UUID, service: any CollectionServing, journal: (any CollectionJournalPersisting)? = nil,
         discovery: CatalogDiscoveryStore? = nil, initialCatalogue: APICatalogue? = nil,
         uptime: @escaping () -> TimeInterval = { LifecycleClock.elapsed }) {
        self.uptime = uptime
        self.userID = userID; self.service = service
        self.discovery = discovery ?? CatalogDiscoveryStore(userID: userID,
            service: UnavailableCatalogDiscoveryRepository(serverID: service.serverID))
        let resolved = journal ?? CollectionJournalStore()
        self.journal = resolved
        self.catalogue = initialCatalogue
        do {
            state = try resolved.load(server: service.serverID, user: userID) ?? CollectionJournalState()
            if let cached = state.milestonesCache {
                milestones = cached
                milestonesConfirmedAt = state.milestonesConfirmedAt
                refreshFailed = true
            }
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
    var canOpenPack: Bool { canMutate && capacity?.plantFull != true }
    func canBuy(quantity: Int) -> Bool { quantity > 0 && quantity <= (capacity?.packRoom ?? 20) }
    func canAfford(_ offer: APIExchangeOffer, quantity: Int) -> Bool {
        guard ["tokens", "gems"].contains(offer.purchaseCurrency),
              let balance = balance(for: offer).flatMap(ExactAmount.integer),
              let cost = ExactAmount.integer(offer.tokenCost) else { return false }
        return (1...20).contains(quantity) && balance >= cost * Decimal(quantity)
    }
    func balance(for offer: APIExchangeOffer) -> String? {
        offer.purchaseCurrency == "gems" ? gemBalance : tokenBalance
    }
    func deactivate() { attached = false; refreshTask?.cancel(); inventoryReconciliation?.cancel(); discovery.deactivate() }
    func applyWallet(_ balance: String, version: Int64, gems: String? = nil) {
        guard attached, version >= economyVersion, ExactAmount.integer(balance) != nil else { return }
        if version > economyVersion { gemBalance = nil }
        if let gems = gems, ExactAmount.integer(gems) != nil { gemBalance = gems }
        guard version > economyVersion else { return }
        tokenBalance = balance; economyVersion = version; onWallet?(balance, version)
    }
    private func persist(_ value: CollectionJournalState) throws {
        var updated = value
        updated.milestoneTrack = value.milestoneTrack ?? state.milestoneTrack
        updated.milestoneScroll = value.milestoneScroll ?? state.milestoneScroll
        updated.milestonesCache = value.milestonesCache ?? state.milestonesCache
        updated.milestonesConfirmedAt = value.milestonesConfirmedAt ?? state.milestonesConfirmedAt
        try journal.save(updated, server: service.serverID, user: userID)
        state = updated
    }
    func rememberMilestone(track: String, anchor: String? = nil) {
        guard attached else { return }
        var updated = state
        updated.milestoneTrack = track
        if let anchor = anchor {
            var positions = updated.milestoneScroll ?? [:]
            positions[track] = anchor
            updated.milestoneScroll = positions
        }
        guard updated.milestoneTrack != state.milestoneTrack || updated.milestoneScroll != state.milestoneScroll else { return }
        do { try persist(updated) }
        catch { message = "Your milestone position could not be saved." }
    }
    private func recover(live: Bool = false) async throws {
        guard let pending = state.pending else { return }
        do {
            DiagnosticHistory.shared.record("Collection", "sending \(pending.kind.rawValue)", requestID: pending.id.uuidString, scope: diagnosticScope)
            let receipt = try await service.mutate(pending)
            guard attached else { return }
            let isOpening = pending.kind == .open
            let matchesOperation: Bool
            switch pending.kind {
            case .expeditionClaim:
                let ids = receipt.ownedItemIds ?? []
                matchesOperation = receipt.requestId == pending.id && receipt.runId == pending.runID &&
                    receipt.entitlementId == pending.entitlementID && receipt.rewardKey != nil &&
                    receipt.tokensEarned.flatMap(ExactAmount.integer) != nil &&
                    receipt.gemsEarned.flatMap(ExactAmount.integer) != nil && Set(ids).count == ids.count
            case .itemPurchase:
                let body = try ActivityWire.decoder().decode(CollectionExchangeBody.self, from: pending.body)
                let ids = receipt.ownedItemIds ?? []
                matchesOperation = receipt.requestId == pending.id && receipt.purchaseId != nil &&
                    receipt.quantity == body.quantity && ids.count == body.quantity && Set(ids).count == ids.count &&
                    receipt.tokensSpent.flatMap(ExactAmount.integer).map { $0 > 0 } == true
            case .itemSell:
                let body = try ActivityWire.decoder().decode(ItemSellBody.self, from: pending.body)
                matchesOperation = receipt.requestId == pending.id && receipt.saleId != nil &&
                    receipt.ownedItemId == pending.target && receipt.tokensEarned == body.expectedTokens
            case .sell:
                let body = try ActivityWire.decoder().decode(CollectionSellBody.self, from: pending.body)
                matchesOperation = receipt.requestId == pending.id && receipt.saleId != nil &&
                    receipt.plantId == pending.target && receipt.tokensEarned == body.expectedTokens
            case .open: matchesOperation = receipt.ownedPackId == pending.target && receipt.plant != nil && receipt.openingId != nil
            case .exchange: matchesOperation = receipt.requestId == pending.id && receipt.exchangeId != nil && receipt.packs?.isEmpty == false
            case .milestone:
                let packs = receipt.packs ?? []
                matchesOperation = receipt.requestId == pending.id && receipt.milestoneId == pending.milestoneID &&
                    receipt.milestoneEventId != nil && receipt.tokensEarned.flatMap(ExactAmount.integer) != nil &&
                    (receipt.gemsEarned == nil || receipt.gemsEarned.flatMap(ExactAmount.integer) != nil) &&
                    (receipt.gemBalance == nil || receipt.gemBalance.flatMap(ExactAmount.integer) != nil) &&
                    Set(packs.map(\.id)).count == packs.count && packs.allSatisfy {
                        $0.version > 0 && $0.packId.range(of: "^[a-z][a-z0-9_-]{0,99}$", options: .regularExpression) != nil
                    }
            }
            guard receipt.economyVersion >= 0, ExactAmount.integer(receipt.tokenBalance) != nil,
                  matchesOperation else {
                throw ForestError.invalidData("The reward response could not be verified. Retry the saved request.")
            }
            // Persist the result and removal together. A disk failure retains the request.
            try persist(CollectionJournalState(pending: nil, result: receipt))
            if isOpening { discovery.invalidate() }
            if let milestoneID = receipt.milestoneId { confirmedMilestoneIDs.insert(milestoneID) }
            confirmedMilestoneIDs.formUnion(receipt.supersededMilestoneIds ?? [])
            if pending.kind == .exchange {
                confirmedExchange = receipt
                exchangeOfferID = (try? ActivityWire.decoder().decode(CollectionExchangeBody.self, from: pending.body))?.offerId
                exchangeMessage = "Purchase confirmed. Your packs are saved."
            }
            let fresh = live && receipt.economyVersion >= economyVersion
            applyWallet(receipt.tokenBalance, version: receipt.economyVersion, gems: receipt.gemBalance)
            if receipt.economyVersion == economyVersion, let capacity = receipt.itemCapacity { itemCapacity = capacity }
            if receipt.economyVersion == economyVersion, let capacity = receipt.capacity {
                acceptCapacity(capacity)
            }
            DiagnosticHistory.shared.record("Collection", "confirmed \(pending.kind.rawValue)", requestID: pending.id.uuidString, scope: diagnosticScope)
            message = pending.kind == .itemPurchase ? "Item saved to Storage." :
                pending.kind == .expeditionClaim ? "Expedition reward saved." :
                pending.kind == .itemSell ? "Item sold for \(receipt.tokensEarned ?? "0") tokens." :
                pending.kind == .sell ? "Plant sold for \(receipt.tokensEarned ?? "0") tokens." :
                pending.kind == .milestone ? "Milestone reward saved." :
                (isOpening ? "Your plant is in Storage." : "Your unopened packs are ready in Packs.")
            let changesInventory = isOpening || pending.kind == .sell || pending.kind == .itemPurchase ||
                pending.kind == .itemSell || pending.kind == .expeditionClaim
            if service.supportsFocusedReads {
                if fresh { applyCollectionChanges(receipt, operation: pending) }
                if changesInventory {
                    let previous = inventoryReconciliation
                    inventoryReconciliation = Task { [weak self] in
                        await previous?.value
                        guard let self = self, self.attached else { return }
                        if fresh, let apply = self.onInventoryReceipt { await apply(receipt) }
                        else { await self.onPlantAwarded?() }
                    }
                }
            } else if changesInventory { await onPlantAwarded?() }
        } catch let error as APIError where (400..<500).contains(error.status) &&
                    ![401, 408, 426, 429].contains(error.status) && error.code != "idempotency_conflict" {
            guard attached else { return }
            try persist(CollectionJournalState(pending: nil, result: state.result))
            throw error
        }
    }
    private func applyCollectionChanges(_ receipt: APICollectionReceipt, operation: PendingCollectionOperation) {
        if let acquired = receipt.packs, packCursor == nil {
            let known = Set(packs.map(\.id))
            packs += acquired.filter { !known.contains($0.id) }
        }
        if let pack = receipt.ownedPackId, receipt.openingId != nil {
            packs.removeAll { $0.id == pack }
            history.removeAll { $0.id == receipt.id }
            history.insert(receipt, at: 0)
        }
        if operation.kind == .itemPurchase {
            if let remaining = receipt.remainingAllowance,
               let index = itemOffers.firstIndex(where: {
                   $0.offerId == receipt.offerId && $0.offerVersion == receipt.offerVersion
               }) {
                itemOffers[index].remainingAllowance = remaining
            } else if let offer = try? ActivityWire.decoder().decode(CollectionExchangeBody.self, from: operation.body),
                      itemOffers.contains(where: { $0.offerId == offer.offerId && $0.remainingAllowance != nil }) {
                deferredRead = .shop // Older servers do not return the updated limited allowance.
            }
        }
        if (operation.kind == .open || operation.kind == .exchange) && receipt.capacity == nil {
            deferredRead = .home
        }
    }

    private func loadCurrent(scope: CollectionReadScope) async throws {
        let sent = uptime()
        let summary = try await service.summary(scope: scope)
        guard attached else { return }
        if scope == .shop || scope == .full {
            if let incoming = summary.shop {
                if let existing = shop, incoming.startsAt < existing.startsAt { return }
                shop = incoming
                shopCountdown = ShopCountdown(rotation: incoming, sent: sent, received: uptime())
                shopRemaining = shopCountdown?.remaining(at: uptime())
            } else { shop = nil; shopCountdown = nil; shopRemaining = nil }
            offers = summary.offers
            itemOffers = summary.itemOffers ?? []
            for offer in offers { definitions[offer.pack.id] = offer.pack }
        }
        applyWallet(summary.tokenBalance, version: summary.economyVersion, gems: summary.gemBalance)
        if summary.economyVersion == economyVersion {
            acceptCapacity(summary.capacity)
            if scope == .shop || scope == .full { itemCapacity = summary.itemCapacity }
        }
        if let rows = summary.milestones, scope != .shop {
            milestonesConfirmedAt = Date()
            // Ordinary reads need not rewrite durable recovery files when facts are identical.
            if state.milestonesCache != rows {
                var updated = state
                updated.milestonesCache = rows
                updated.milestonesConfirmedAt = milestonesConfirmedAt
                try persist(updated)
            }
            milestones = rows
        }
        guard scope != .home, scope != .shop else { return }
        if catalogue == nil || summary.catalogVersion == nil || catalogue?.catalogVersion != summary.catalogVersion {
            let catalogue = try await service.catalogue()
            guard attached else { return }
            self.catalogue = catalogue
        }
        guard scope != .catalog else { return }
        let page = try await service.packs(after: nil)
        guard attached else { return }
        try await loadDefinitions(page.packs)
        guard attached else { return }
        packs = page.packs; packCursor = page.nextCursor
        let history = try await (scope == .packs ? service.latestOpening() : service.openings(after: nil))
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
    func refreshOnArrival(scope: CollectionReadScope) async {
        if service.supportsFocusedReads, (scope == .shop || scope == .packs),
           state.pending == nil, !refreshFailed, let previous = refreshedAt[scope],
           uptime() - previous < 10, scope != .shop || (shopRemaining ?? 1) > 0 {
            return
        }
        await refresh(scope: scope)
    }

    func refresh(scope requested: CollectionReadScope = .full) async {
        let scope = service.supportsFocusedReads ? requested : .full
        if let prior = refreshTask {
            let coversRequest = refreshScope == scope || refreshScope == .full
            await prior.value
            if coversRequest { return }
            await refresh(scope: scope)
            return
        }
        guard attached, !busy, !recoveryLocked else { return }
        busy = true; refreshFailed = false; message = nil
        refreshScope = scope
        // SwiftUI can cancel the swipe's task as its refresh control updates.
        // Finish the same refresh/recovery independently; account guards still apply.
        let work = Task { @MainActor in
            defer { busy = false; refreshTask = nil; refreshScope = nil }
            do {
                try await recover()
                guard attached else { return }
                try await loadCurrent(scope: scope)
                if attached { refreshedAt[scope] = uptime() }
            }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { if attached {
                refreshFailed = true
                message = displayFailure(error)
                if state.pending?.kind == .exchange { exchangeMessage = "Purchase confirmation interrupted. Retry the saved request to recover its result." }
                else if exchangeOfferID != nil && confirmedExchange == nil { exchangeMessage = message }
            } }
        }
        refreshTask = work
        await work.value
    }
    private func submit(_ operation: PendingCollectionOperation) async {
        guard canMutate else { return }
        busy = true; refreshFailed = false; message = nil; defer { busy = false }
        do {
            try operation.validate()
            try persist(CollectionJournalState(pending: operation, result: state.result))
            try await recover(live: true)
            guard attached else { return }
            if !service.supportsFocusedReads {
                try await loadCurrent(scope: .full)
            } else if let scope = deferredRead {
                deferredRead = nil
                Task { [weak self] in await self?.refresh(scope: scope) }
            }
        } catch { if attached {
            refreshFailed = true
            message = displayFailure(error)
            if let error = error as? APIError,
               ["stale_offer", "item_allowance_used", "item_capacity_full"].contains(error.code),
               service.supportsFocusedReads {
                shopRefreshNeeded = true
            }
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
        guard canMutate, canAfford(offer, quantity: quantity), canBuy(quantity: quantity) else { return }
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
            if pending.kind == .open && pending.target == pack.id { await refresh(scope: .packs) }
            return
        }
        guard canOpenPack else { return }
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
    func claimExpedition(run: UUID, entitlement: UUID) async {
        guard canMutate else { return }
        do {
            let id = UUID()
            let body = try ActivityWire.encoder().encode(CollectionOpenBody(requestId: id))
            await submit(PendingCollectionOperation(id: id, kind: .expeditionClaim, target: nil,
                body: body, runID: run, entitlementID: entitlement))
        } catch { message = "The expedition claim could not be saved. Try again." }
    }
    func saleQuote(plant: UUID) async throws -> APIPlantSaleQuote {
        guard attached, !recoveryLocked, state.pending == nil else {
            throw ForestError.invalidData("Recover the saved collection request before selling.")
        }
        let quote = try await service.saleQuote(plant: plant)
        guard attached, quote.plantId == plant, ExactAmount.integer(quote.tokens) != nil,
              ExactAmount.integer(quote.growthMicroUnits) != nil else {
            throw ForestError.invalidData("The plant's resale value could not be verified.")
        }
        return quote
    }
    func sell(_ quote: APIPlantSaleQuote) async {
        guard canMutate else { return }
        let id = UUID()
        do {
            let body = try ActivityWire.encoder().encode(CollectionSellBody(requestId: id,
                valuationVersion: quote.valuationVersion, expectedTokens: quote.tokens,
                expectedGrowthMicroUnits: quote.growthMicroUnits))
            await submit(PendingCollectionOperation(id: id, kind: .sell, target: quote.plantId, body: body))
        } catch { message = displayFailure(error) }
    }
    func dismissResult() {
        do { try persist(CollectionJournalState(pending: state.pending, result: nil)) }
        catch { message = "The result could not be dismissed. It is still saved." }
    }

    func canBuyItem(_ offer: APIItemShopOffer, quantity: Int) -> Bool {
        let current = itemOffers.first { $0.id == offer.id }
        guard itemOfferCurrent(offer), quantity <= (current?.remainingAllowance ?? offer.remainingAllowance ?? 20) else { return false }
        guard canMutate, (1...20).contains(quantity), quantity <= (itemCapacity?.room ?? 0),
              let cost = ExactAmount.integer(offer.tokenCost), cost > 0,
              let balance = tokenBalance.flatMap(ExactAmount.integer) else { return false }
        return balance >= cost * Decimal(quantity)
    }

    func itemOfferCurrent(_ offer: APIItemShopOffer) -> Bool {
        guard attached, !refreshFailed else { return false }
        if offer.endsAt == nil { return shop == nil }
        return (shopCountdown?.remaining(at: uptime()) ?? 0) > 0 &&
            offer.endsAt == shop?.endsAt && itemOffers.contains { $0.id == offer.id }
    }

    func requestShopRefresh() async {
        shopRefreshNeeded = true
        shopRetryAfter = 0
        await tickShop()
    }

    func tickShop() async {
        guard attached else { return }
        shopRemaining = shopCountdown?.remaining(at: uptime())
        if shopRemaining == 0 { shopRefreshNeeded = true }
        guard shopRefreshNeeded, uptime() >= shopRetryAfter, !busy, !recoveryLocked else { return }
        shopRefreshNeeded = false
        await refresh(scope: .shop)
        if refreshFailed { shopRefreshNeeded = true; shopRetryAfter = uptime() + 15 }
    }

    func buyItem(_ offer: APIItemShopOffer, quantity: Int) async {
        guard canBuyItem(offer, quantity: quantity) else { return }
        let id = UUID()
        do {
            let body = try ActivityWire.encoder().encode(CollectionExchangeBody(requestId: id,
                offerId: offer.offerId, offerVersion: offer.offerVersion, quantity: quantity))
            await submit(PendingCollectionOperation(id: id, kind: .itemPurchase, target: nil, body: body))
        } catch { message = displayFailure(error) }
    }

    func itemSaleQuote(item: UUID) async throws -> APIItemSaleQuote {
        guard attached, !recoveryLocked, state.pending == nil else {
            throw ForestError.invalidData("Recover the saved collection request before selling.")
        }
        let quote = try await service.itemSaleQuote(item: item)
        guard attached, quote.ownedItemId == item, quote.resaleBasisPoints == 2500,
              !quote.valuationVersion.isEmpty,
              let value = ExactAmount.integer(quote.tokenValue), value >= 4,
              let tokens = ExactAmount.integer(quote.tokens), tokens > 0,
              tokens == Decimal(NSDecimalNumber(decimal: value).int64Value / 4) else {
            throw ForestError.invalidData("The item's resale value could not be verified.")
        }
        return quote
    }

    func sellItem(_ quote: APIItemSaleQuote) async {
        guard canMutate else { return }
        let id = UUID()
        do {
            let body = try ActivityWire.encoder().encode(ItemSellBody(requestId: id,
                valuationVersion: quote.valuationVersion, expectedTokens: quote.tokens))
            await submit(PendingCollectionOperation(id: id, kind: .itemSell, target: quote.ownedItemId, body: body))
        } catch { message = displayFailure(error) }
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
