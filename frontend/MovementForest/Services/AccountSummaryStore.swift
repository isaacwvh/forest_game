import Foundation
import Combine

@MainActor
protocol AccountSummaryPersisting {
    func load(server: String, user: UUID) throws -> AccountSummaryCache?
    func save(_ value: AccountSummaryCache, server: String, user: UUID) throws
}

struct AccountSummaryDiskStore: AccountSummaryPersisting {
    let disk: AccountDiskStore
    init(disk: AccountDiskStore = AccountDiskStore()) { self.disk = disk }
    func load(server: String, user: UUID) throws -> AccountSummaryCache? {
        try disk.load(AccountSummaryCache.self, kind: "account-summary", server: server, user: user)
    }
    func save(_ value: AccountSummaryCache, server: String, user: UUID) throws {
        try disk.save(value, kind: "account-summary", server: server, user: user)
    }
}

/// Read-only shared state. Failure here never blocks the durable mutation journals.
@MainActor
final class AccountSummaryStore: ObservableObject {
    @Published private(set) var snapshot: APIAccountSummary?
    @Published private(set) var refreshing = false
    @Published private(set) var lastConfirmed = true
    @Published private(set) var failed = false
    var onWallet: ((String, Int64) -> Void)?
    private let userID: UUID
    private let service: any AccountSummaryServing
    private let cache: any AccountSummaryPersisting
    private var attached = true
    private var dirty = true
    private var hasLiveConfirmation = false
    private var minimumEconomyVersion: Int64 = 0
    private var refreshTask: Task<Void, Never>?

    // Keep restored/stale data labelled, but do not flash a saved-data banner
    // while a previously confirmed account updates after an ordinary reward.
    var showsSavedProgress: Bool {
        snapshot != nil && lastConfirmed && (!hasLiveConfirmation || (!dirty && !refreshing))
    }

    init(userID: UUID, service: any AccountSummaryServing,
         cache: (any AccountSummaryPersisting)? = nil) {
        self.userID = userID; self.service = service
        self.cache = cache ?? AccountSummaryDiskStore()
        do {
            if let saved = try self.cache.load(server: service.serverID, user: userID) {
                snapshot = try saved.snapshot.validated(user: userID)
                minimumEconomyVersion = saved.snapshot.wallet.economyVersion
            }
        } catch { failed = true }
    }

    func deactivate() {
        attached = false; snapshot = nil; refreshTask?.cancel()
    }

    func invalidate() {
        guard attached else { return }
        dirty = true; lastConfirmed = true
        Task { [weak self] in await self?.refresh() }
    }

    func economyChanged(_ version: Int64) {
        guard attached, version > minimumEconomyVersion else { return }
        minimumEconomyVersion = version
        invalidate()
    }

    func receive(progression: APIAccountProgression?, wallet: APIAccountWallet?) {
        guard attached else { return }
        if let p = progression, let w = wallet, let current = snapshot {
            do {
                let incoming = APIAccountSummary(serverTime: current.serverTime, profile: current.profile,
                                                 progression: p, wallet: w)
                try merge(incoming)
            } catch { failed = true }
        }
        // A historical or compacted receipt is not the current account snapshot.
        invalidate()
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
        if attached && dirty && !failed { await refresh() }
    }

    private func merge(_ value: APIAccountSummary) throws {
        let incoming = try value.validated(user: userID)
        var merged = incoming
        if let current = snapshot {
            if incoming.progression.version < current.progression.version {
                merged.progression = current.progression
            } else if incoming.progression.version == current.progression.version {
                // The disk wire codec preserves milliseconds. Compare its canonical form so
                // sub-millisecond timestamp precision cannot turn a valid cache into a conflict.
                let encoder = ActivityWire.encoder()
                encoder.outputFormatting = [.sortedKeys]
                let incomingData = try encoder.encode(incoming.progression)
                let currentData = try encoder.encode(current.progression)
                if incomingData != currentData {
                    throw ForestError.invalidData("Conflicting account progression version.")
                }
            }
            if incoming.wallet.economyVersion < current.wallet.economyVersion {
                merged.wallet = current.wallet
            } else if incoming.wallet.economyVersion == current.wallet.economyVersion && incoming.wallet != current.wallet {
                throw ForestError.invalidData("Conflicting account wallet version.")
            }
        }
        let previous = snapshot
        snapshot = try merged.validated(user: userID)
        if previous?.progression != merged.progression || previous?.wallet != merged.wallet {
            let p = merged.progression
            DiagnosticHistory.shared.record("Progression",
                "steps=\(p.lifetimeRecordedSteps) gems=\(merged.wallet.gemBalance) level=\(p.level) xp=\(p.xpIntoLevel)/\(p.xpForNextLevel) nextGem=\(p.stepsIntoNextGem)/\(p.stepsPerGem)",
                scope: DiagnosticHistory.scope(server: service.serverID, user: userID))
        }
        minimumEconomyVersion = max(minimumEconomyVersion, merged.wallet.economyVersion)
        if previous?.wallet != merged.wallet {
            onWallet?(merged.wallet.tokenBalance, merged.wallet.economyVersion)
        }
        do {
            try cache.save(AccountSummaryCache(snapshot: merged, confirmedAt: Date()),
                           server: service.serverID, user: userID)
        } catch { lastConfirmed = true }
    }

    private func fetch() async {
        refreshing = true
        defer { refreshing = false }
        repeat {
            dirty = false
            do {
                let incoming = try await service.accountSummary()
                guard attached, !Task.isCancelled else { return }
                try merge(incoming)
                failed = false
                lastConfirmed = dirty || (snapshot?.wallet.economyVersion ?? -1) < minimumEconomyVersion ||
                    snapshot?.progression != incoming.progression || snapshot?.wallet != incoming.wallet
                if !lastConfirmed { hasLiveConfirmation = true }
            } catch {
                guard attached else { return }
                failed = true; lastConfirmed = true; dirty = true
                return
            }
        } while attached && dirty
    }
}
