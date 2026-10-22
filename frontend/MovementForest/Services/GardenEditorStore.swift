import Foundation
import Combine

struct GardenCandidate: Equatable {
    let plant: APIOwnedPlant
    let kind: GardenEditKind
    var x: Decimal
    var y: Decimal
    var rotation: Decimal
    var validity: PlacementValidity = .unavailable
}

enum GardenSaveState: Equatable {
    case ready, loading, saving, unknown, authenticationRequired, blocked
    var busy: Bool { self == .loading || self == .saving }
}

@MainActor
final class GardenEditorStore: ObservableObject, Identifiable {
    let id = UUID()
    let profile: APIProfile
    private(set) var service: any GardenServing
    private let assets: any AssetCatalogProviding
    private let journal: any PendingEditPersisting
    private let cache: AccountDiskStore?
    @Published private(set) var confirmedAt: Date?
    @Published private(set) var showingCached = false
    @Published private(set) var activityBusy = false
    @Published private(set) var preparingMembership = false
    @Published var activityBlocked = false
    var prepareMembershipChange: (() async -> Bool)?
    var reconcileActivity: (() async -> Void)?
    @Published private(set) var catalogue: APICatalogue?
    @Published private(set) var confirmed: APIGarden?
    @Published private(set) var rendered: GardenSnapshot?
    @Published private(set) var inventory: [APIOwnedPlant] = []
    @Published private(set) var nextCursor: UUID?
    @Published private(set) var candidate: GardenCandidate?
    @Published private(set) var pending: PendingGardenEdit?
    @Published private(set) var state: GardenSaveState = .loading
    @Published private(set) var message: String?
    @Published private(set) var inventoryLoading = false
    @Published private(set) var recoveryLocked = false
    @Published var selectedID: UUID?
    @Published var editing = false
    @Published var adultPreview = false
    private var needsRefresh = true
    private var refreshInFlight = false
    private var inventoryGeneration = UUID()
    private var started = false
    private var lastReadIssue: String?
    private(set) var isActive = true

    func deactivate() {
        isActive = false; inventoryGeneration = UUID(); endEditing()
        prepareMembershipChange = nil; reconcileActivity = nil
        state = .blocked
    }

    init(profile: APIProfile, service: any GardenServing, assets: any AssetCatalogProviding,
         journal: any PendingEditPersisting = PendingGardenEditStore(), cache: AccountDiskStore? = nil) {
        self.profile = profile; self.service = service; self.assets = assets; self.journal = journal
        self.cache = cache
    }

    var canEdit: Bool { readyForMutation && !activityBusy && !preparingMembership && !activityBlocked }
    private var readyForMutation: Bool {
        isActive && state == .ready && pending == nil && !needsRefresh && !recoveryLocked && confirmed != nil && catalogue != nil
    }
    var connectionBusy: Bool { state.busy || activityBusy || preparingMembership }
    var selected: APIOwnedPlant? { confirmed?.plants.first { $0.id == selectedID } ?? inventory.first { $0.id == selectedID } }
    var pendingRequestID: String? {
        guard let pending = pending else { return nil }
        return (try? pending.request)?.requestId.uuidString
    }
    func render(_ plant: APIOwnedPlant) -> GardenPlant? {
        catalogue.map { plant.rendered(catalogue: $0, assets: assets) }
    }

    func start(refreshRemote: Bool = true) async {
        started = true
        restoreCached()
        do {
            pending = try journal.load(server: service.serverID, user: profile.userId)
        } catch {
            recoveryLocked = true
            state = .blocked; message = "The saved edit could not be read. Editing is paused to protect that operation."
            return
        }
        if !refreshRemote {
            state = pending == nil ? .blocked : .unknown
            return
        }
        if pending != nil { await retryPending() } else { await refresh() }
    }

    func restoreCached() {
        defer { if state == .loading { state = .blocked } }
        guard confirmed == nil, let cache = cache else { return }
        do {
            guard let value = try cache.load(ConfirmedGardenCache.self, kind: "garden", server: service.serverID, user: profile.userId),
                  value.serverID == service.serverID, value.profile.userId == profile.userId else { return }
            let snapshot = try value.garden.rendered(catalogue: value.catalogue, assets: assets)
            catalogue = value.catalogue; confirmed = value.garden; rendered = snapshot
            inventory = filtered(value.inventory, garden: value.garden); nextCursor = value.nextCursor
            confirmedAt = value.confirmedAt; showingCached = true
        } catch {
            message = "The cached garden could not be read. Reconnect to refresh it."
            lastReadIssue = message
        }
    }

    private func persistConfirmed() throws {
        guard let cache = cache, let catalogue = catalogue, let confirmed = confirmed else { return }
        try cache.save(ConfirmedGardenCache(serverID: service.serverID, profile: profile,
                                           confirmedAt: confirmedAt ?? Date(), catalogue: catalogue,
                                           garden: confirmed, inventory: inventory, nextCursor: nextCursor),
                       kind: "garden", server: service.serverID, user: profile.userId)
    }

    /// All editor and activity receipts meet here. Historical receipts can never
    /// replace newer confirmed state, even when they arrive after a relaunch.
    func applyConfirmed(_ garden: APIGarden, at date: Date = Date(), updatedPlants: [APIOwnedPlant] = []) throws {
        guard isActive else { throw CancellationError() }
        guard let catalogue = catalogue, garden.catalogVersion == catalogue.catalogVersion else { return }
        if let current = confirmed {
            guard current.gardenId == garden.gardenId else { throw ForestError.invalidData("Unexpected garden identity.") }
            guard garden.stateVersion >= current.stateVersion, garden.layoutVersion >= current.layoutVersion else { return }
        }
        let snapshot = try garden.rendered(catalogue: catalogue, assets: assets)
        confirmed = garden; rendered = snapshot
        inventory = filtered(inventory.filter { old in !updatedPlants.contains(where: { $0.id == old.id }) } + updatedPlants, garden: garden)
        confirmedAt = date; showingCached = false
        try persistConfirmed()
    }

    func beginActivityOperation() -> Bool {
        guard isActive, !activityBusy, !state.busy, pending == nil, !refreshInFlight, !recoveryLocked else { return false }
        activityBusy = true; cancelCandidate()
        return true
    }
    func endActivityOperation() { activityBusy = false }

    func reconcile() async {
        if let reconcileActivity = reconcileActivity { await reconcileActivity() }
        else if pending != nil { await retryPending() }
        else { await refresh() }
    }

    func replaceService(_ replacement: any GardenServing) async {
        guard service.serverID == replacement.serverID, !state.busy else { return }
        service = replacement
        if !started { await start(); return }
        if pending != nil { await retryPending() } else { await refresh() }
    }

    func refresh() async {
        guard isActive, pending == nil, !refreshInFlight, !recoveryLocked else { return }
        refreshInFlight = true
        state = .loading; candidate = nil; needsRefresh = true
        inventoryGeneration = UUID()
        defer { refreshInFlight = false }
        do {
            // Individual reads are coherent, but not an atomic bootstrap. Bound retries
            // if another client keeps changing the layout/catalogue during this read.
            for _ in 0..<3 {
                let catalog = try await service.catalogue()
                let before = try await service.garden()
                let page = try await service.inventory(after: nil)
                let after = try await service.garden()
                guard isActive else { return }
                guard before.stateVersion == after.stateVersion, before.layoutVersion == after.layoutVersion, before.catalogVersion == after.catalogVersion,
                      catalog.catalogVersion == after.catalogVersion else { continue }
                if let current = confirmed {
                    guard after.gardenId == current.gardenId, after.stateVersion >= current.stateVersion,
                          after.layoutVersion >= current.layoutVersion else { continue }
                }
                let snapshot = try after.rendered(catalogue: catalog, assets: assets)
                _ = try PlacementGeometry.units(after.width)
                _ = try PlacementGeometry.units(after.depth)
                catalogue = catalog; confirmed = after; rendered = snapshot
                inventory = filtered(page.plants, garden: after); nextCursor = page.nextCursor
                confirmedAt = Date(); showingCached = false
                try persistConfirmed()
                needsRefresh = false; state = .ready
                if message == lastReadIssue { message = nil }
                lastReadIssue = nil
                if !allOwnedIDs.contains(selectedID ?? UUID()) { selectedID = nil }
                return
            }
            throw ForestError.invalidData("Your garden changed while loading. Refresh to try again.")
        } catch {
            showingCached = confirmed != nil
            state = (error as? APIError)?.status == 401 ? .authenticationRequired : .blocked
            message = error.localizedDescription
            lastReadIssue = message
        }
    }

    private var allOwnedIDs: Set<UUID> { Set((confirmed?.plants ?? []).map(\.id) + inventory.map(\.id)) }
    private func filtered(_ plants: [APIOwnedPlant], garden: APIGarden) -> [APIOwnedPlant] {
        let placed = Set(garden.plants.map(\.id))
        var seen = Set<UUID>()
        return plants.filter { $0.placement == nil && !placed.contains($0.id) && seen.insert($0.id).inserted }
    }

    func loadMore() async {
        guard canEdit, !inventoryLoading, let cursor = nextCursor else { return }
        inventoryLoading = true
        let generation = inventoryGeneration
        defer { inventoryLoading = false }
        do {
            let page = try await service.inventory(after: cursor)
            guard isActive, generation == inventoryGeneration, let garden = confirmed else { return }
            inventory = filtered(inventory + page.plants, garden: garden)
            nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
            try persistConfirmed()
        } catch { message = "Stored plants could not load. \(error.localizedDescription)" }
    }

    func begin(_ plant: APIOwnedPlant, kind: GardenEditKind) {
        guard canEdit, let garden = confirmed, let catalogue = catalogue else { return }
        cancelCandidate()
        selectedID = plant.id; message = nil; adultPreview = false
        if kind != .rotate {
            do { _ = try catalogue.radius(for: plant) }
            catch { message = error.localizedDescription; return }
        }
        let x = plant.placement?.x ?? garden.width / 2
        let y = plant.placement?.y ?? garden.depth / 2
        candidate = GardenCandidate(plant: plant, kind: kind, x: x, y: y,
                                    rotation: plant.placement?.rotationDegrees ?? 0)
        validateCandidate()
    }

    func updatePosition(x: Double, y: Double) {
        guard canEdit, var candidate = candidate,
              let canonicalX = PlacementGeometry.canonical(x), let canonicalY = PlacementGeometry.canonical(y) else {
            invalidateCandidate(); return
        }
        candidate.x = canonicalX; candidate.y = canonicalY
        self.candidate = candidate; validateCandidate()
    }
    func updateRotation(_ angle: Double) {
        guard canEdit, let angle = PlacementGeometry.rotation(angle), var candidate = candidate else { return }
        candidate.rotation = angle; self.candidate = candidate; validateCandidate()
    }
    func invalidateCandidate() {
        guard var candidate = candidate else { return }
        candidate.validity = .outOfBounds; self.candidate = candidate
    }
    func cancelCandidate() { candidate = nil; adultPreview = false }
    func endEditing() { cancelCandidate(); editing = false; selectedID = nil }

    private func validateCandidate() {
        guard var candidate = candidate, let garden = confirmed, let catalogue = catalogue else { return }
        if candidate.kind == .rotate { candidate.validity = .valid; self.candidate = candidate; return }
        do {
            var circles = try garden.plants.filter { $0.id != candidate.plant.id }.map { plant -> PlacementCircle in
                guard let placement = plant.placement else { throw ForestError.invalidData("Missing placement.") }
                return PlacementCircle(id: plant.id, x: try PlacementGeometry.units(placement.x),
                                       y: try PlacementGeometry.units(placement.y), radius: try catalogue.radius(for: plant))
            }
            // Negative candidates are visibly invalid, never clamped to a valid edge.
            guard candidate.x >= 0, candidate.y >= 0 else {
                candidate.validity = .outOfBounds; self.candidate = candidate; return
            }
            circles.append(PlacementCircle(id: candidate.plant.id, x: try PlacementGeometry.units(candidate.x),
                                            y: try PlacementGeometry.units(candidate.y), radius: try catalogue.radius(for: candidate.plant)))
            candidate.validity = PlacementGeometry.validate(width: try PlacementGeometry.units(garden.width),
                                                           depth: try PlacementGeometry.units(garden.depth), circles: circles)
        } catch { candidate.validity = .unavailable }
        self.candidate = candidate
    }

    func releaseCandidate() async {
        guard let candidate = candidate else { return }
        guard candidate.validity == .valid else { message = candidate.validity.message; cancelCandidate(); return }
        await submit(GardenEditAction(action: candidate.kind, plantId: candidate.plant.id,
                                     x: candidate.kind == .rotate ? nil : candidate.x,
                                     y: candidate.kind == .rotate ? nil : candidate.y,
                                     rotationDegrees: candidate.rotation))
    }

    func storeSelected() async {
        guard let plant = selected, plant.placement != nil else { return }
        cancelCandidate()
        await submit(GardenEditAction(action: .store, plantId: plant.id))
    }

    private func submit(_ action: GardenEditAction) async {
        guard canEdit else { return }
        preparingMembership = true
        defer { preparingMembership = false }
        if (action.action == .plant || action.action == .store), let prepare = prepareMembershipChange {
            guard await prepare() else {
                message = "Activity could not be confirmed before changing planted plants. Retry sync, then try this edit again."
                cancelCandidate(); return
            }
        }
        guard readyForMutation, !activityBusy, !activityBlocked, let garden = confirmed else { return }
        let request = GardenEditRequest(requestId: UUID(), expectedLayoutVersion: garden.layoutVersion,
                                        catalogVersion: garden.catalogVersion, actions: [action])
        do {
            let edit = PendingGardenEdit(serverID: service.serverID, userID: profile.userId,
                                         gardenID: garden.gardenId, body: try request.encoded())
            try journal.save(edit) // Must succeed before any network transmission.
            pending = edit
        } catch { message = "Your edit could not be saved on this device. Nothing was sent."; cancelCandidate(); return }
        cancelCandidate()
        await retryPending()
    }

    func retryPending() async {
        guard isActive, (!state.busy || state == .loading), !refreshInFlight, !recoveryLocked, let edit = pending else { return }
        guard state != .saving, edit.serverID == service.serverID, edit.userID == profile.userId else { return }
        state = .saving; message = "Saving…"; inventoryGeneration = UUID()
        do {
            let request = try edit.request
            let result = try await service.edit(body: edit.body)
            guard isActive else { return }
            guard result.requestId == request.requestId, result.garden.gardenId == edit.gardenID else {
                throw ForestError.invalidData("The server returned an unexpected edit receipt.")
            }
            // A replay may contain an older catalogue/snapshot: refresh current state
            // after acknowledging the durable receipt, rather than displaying it as current.
            if let catalogue = catalogue, result.garden.catalogVersion == catalogue.catalogVersion,
               confirmed == nil || result.garden.stateVersion >= (confirmed?.stateVersion ?? 0) {
                try applyConfirmed(result.garden, updatedPlants: result.updatedPlants)
            }
            try journal.remove(server: edit.serverID, user: edit.userID)
            pending = nil; needsRefresh = true; state = .ready
            message = "Saved."
            await refresh()
        } catch let error as APIError where (400..<500).contains(error.status) && error.status != 408 && error.status != 429 {
            if error.status == 401 {
                state = .authenticationRequired; message = "Sign in again to finish confirming this edit. Your saved request is retained."
                return
            }
            if error.code == "idempotency_conflict" {
                recoveryLocked = true
                state = .blocked; message = "The saved request conflicts with a server receipt. Editing is paused; inspect the request ID in development diagnostics."
                return
            }
            do { try journal.remove(server: edit.serverID, user: edit.userID); pending = nil }
            catch { state = .blocked; message = "The rejected edit could not be cleared on this device."; return }
            message = error.message; state = .ready; needsRefresh = true
            await refresh()
        } catch {
            state = .unknown
            message = "Save not confirmed. The server may have saved it. Retry this edit before making another change."
        }
    }
}
