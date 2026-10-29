import Foundation
import Combine

@MainActor
protocol CatalogDiscoveryPersisting {
    func load(server: String, user: UUID) throws -> CatalogDiscoveryCache?
    func save(_ value: CatalogDiscoveryCache, server: String, user: UUID) throws
}

struct CatalogDiscoveryDiskStore: CatalogDiscoveryPersisting {
    let disk: AccountDiskStore
    init(disk: AccountDiskStore = AccountDiskStore()) { self.disk = disk }
    func load(server: String, user: UUID) throws -> CatalogDiscoveryCache? {
        try disk.load(CatalogDiscoveryCache.self, kind: "catalog-discovery", server: server, user: user)
    }
    func save(_ value: CatalogDiscoveryCache, server: String, user: UUID) throws {
        try disk.save(value, kind: "catalog-discovery", server: server, user: user)
    }
}

@MainActor
final class CatalogDiscoveryStore: ObservableObject {
    @Published private(set) var snapshot: APICatalogDiscovery?
    @Published private(set) var refreshing = false
    @Published private(set) var lastConfirmed = true
    @Published private(set) var failed = false
    private let userID: UUID
    private let service: any CatalogDiscoveryServing
    private let cache: any CatalogDiscoveryPersisting
    private var attached = true
    private var dirty = true
    private var viewers = Set<UUID>()
    private var refreshTask: Task<Void, Never>?

    init(userID: UUID, service: any CatalogDiscoveryServing, cache: (any CatalogDiscoveryPersisting)? = nil) {
        self.userID = userID; self.service = service
        self.cache = cache ?? CatalogDiscoveryDiskStore()
        do {
            if let saved = try self.cache.load(server: service.serverID, user: userID) {
                snapshot = try saved.snapshot.validated(user: userID)
            }
        } catch {
            // This read-only cache never locks mutation recovery or exposes unverified art.
            failed = true
        }
    }

    func revealed(species: String, variant: String, stage: GrowthStage) -> Bool {
        stage == .sprout || (attached && snapshot?.keys.contains(
            CatalogDiscoveryKey(species: species, variant: variant, stage: stage)) == true)
    }

    func status(species: String, variant: String, stage: GrowthStage) -> String {
        if stage == .sprout { return "Always visible" }
        guard snapshot != nil, attached else {
            return failed && !refreshing ? "Discovery unavailable" : "Checking discovery…"
        }
        return revealed(species: species, variant: variant, stage: stage) ? "Discovered" : "Not discovered"
    }

    func beginViewing(_ id: UUID) { viewers.insert(id) }
    func endViewing(_ id: UUID) { viewers.remove(id) }
    func invalidate() {
        guard attached else { return }
        dirty = true; lastConfirmed = true
        if !viewers.isEmpty {
            Task { [weak self] in
                guard let self = self, self.attached, self.dirty else { return }
                await self.refresh()
            }
        }
    }
    func deactivate() {
        attached = false; viewers = []; snapshot = nil
        refreshTask?.cancel()
    }

    func refresh() async {
        guard attached else { return }
        if let running = refreshTask { await running.value; return }
        let work = Task<Void, Never> { [weak self] in
            guard let self = self else { return }
            await self.fetch()
        }
        refreshTask = work
        await work.value
        refreshTask = nil
        // An invalidation can arrive after fetch finishes but before its owner
        // clears the coalesced task. Preserve that final confirmation refresh.
        if attached && dirty && !failed && !viewers.isEmpty { await refresh() }
    }

    private func fetch() async {
        refreshing = true
        defer { refreshing = false }
        repeat {
            dirty = false
            do {
                let incoming = try await service.discovery().validated(user: userID)
                guard attached, !Task.isCancelled else { return }
                if let current = snapshot {
                    if incoming.discoveryVersion < current.discoveryVersion { lastConfirmed = true; return }
                    guard incoming.keys.isSuperset(of: current.keys),
                          incoming.discoveryVersion != current.discoveryVersion || incoming.keys == current.keys else {
                        throw ForestError.invalidData("Catalog discovery cannot remove confirmed stages.")
                    }
                }
                // Mark as last confirmed if growth invalidated this request while it was in flight.
                snapshot = incoming; lastConfirmed = dirty; failed = false
                do {
                    try cache.save(CatalogDiscoveryCache(snapshot: incoming, confirmedAt: Date()),
                                   server: service.serverID, user: userID)
                } catch {
                    // The verified server result remains usable even if this device cannot cache it.
                    lastConfirmed = true
                }
            } catch {
                guard attached else { return }
                failed = true; lastConfirmed = true; dirty = true
                return
            }
        } while attached && dirty && !viewers.isEmpty
    }
}
