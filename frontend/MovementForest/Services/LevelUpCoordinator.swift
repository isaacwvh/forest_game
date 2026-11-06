import Foundation
import Combine

struct LevelUpPresentationCache: Codable {
    struct Pending: Codable { let notice: APILevelUpNotice; let requestID: UUID; let installationID: UUID }
    let owner: UUID
    let server: String
    var pending: Pending?
    var shown: [UUID] = []
}

@MainActor
protocol LevelUpPersisting {
    func load(server: String, user: UUID) throws -> LevelUpPresentationCache?
    func save(_ value: LevelUpPresentationCache) throws
}

struct LevelUpDiskStore: LevelUpPersisting {
    let disk: AccountDiskStore
    func load(server: String, user: UUID) throws -> LevelUpPresentationCache? {
        try disk.load(LevelUpPresentationCache.self, kind: "level-up-presentation", server: server, user: user)
    }
    func save(_ value: LevelUpPresentationCache) throws {
        try disk.save(value, kind: "level-up-presentation", server: value.server, user: value.owner)
    }
}

/// Presentation is consumed before mounting. Rewards never depend on this flow.
@MainActor
final class LevelUpCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var presented: APILevelUpNotice?
    var onConsumed: (() -> Void)?
    private let service: any LevelUpServing
    private let persistence: any LevelUpPersisting
    private let installation: UUID
    private var saved: LevelUpPresentationCache
    private var available: APILevelUpNotice?
    private var eligible = false
    private var busy = false
    private var attached = true
    private var cacheLocked = false

    init(user: UUID, server: String, installation: UUID, service: any LevelUpServing,
         persistence: any LevelUpPersisting) {
        self.installation = installation; self.service = service; self.persistence = persistence
        saved = LevelUpPresentationCache(owner: user, server: server)
        do {
            if let cache = try persistence.load(server: server, user: user) {
                guard cache.owner == user, cache.server == server, cache.shown.count <= 64 else {
                    throw ForestError.invalidData("Unexpected level-up cache.")
                }
                try cache.pending?.notice.validate()
                saved = cache
            }
        } catch { cacheLocked = true }
    }

    func receive(_ notice: APILevelUpNotice?) {
        guard attached else { return }
        available = notice
        schedule()
    }

    func setEligible(_ value: Bool) {
        eligible = value
        if !value { presented = nil }
        schedule()
    }

    func dismiss() { presented = nil; onConsumed?(); schedule() }

    func deactivate() { attached = false; eligible = false; presented = nil; available = nil }

    private func schedule() {
        guard attached, eligible, !busy, !cacheLocked, presented == nil,
              saved.pending != nil || available != nil else { return }
        busy = true
        Task { [weak self] in await self?.presentIfReady() }
    }

    private func persist(_ value: LevelUpPresentationCache) throws {
        try persistence.save(value)
        saved = value
    }

    private func presentIfReady() async {
        defer { busy = false }
        guard attached, eligible else { return }
        do {
            if saved.pending == nil, let notice = available {
                try notice.validate()
                if saved.shown.contains(notice.id) { available = nil; return }
                var next = saved
                next.pending = .init(notice: notice, requestID: UUID(), installationID: installation)
                try persist(next)
            }
            guard let pending = saved.pending else { return }
            let result = try await service.claim(notice: pending.notice.id, request: pending.requestID,
                                                 installation: pending.installationID)
            guard attached else { return }
            try result.notice.validate()
            guard result.notice == pending.notice else { throw ForestError.invalidData("Conflicting level-up receipt.") }
            if !result.mayPresent {
                var next = saved; next.pending = nil
                try persist(next); available = nil; onConsumed?()
                return
            }
            guard eligible else { return } // Original claim survives for recovery.
            var next = saved
            next.shown = Array((next.shown + [pending.notice.id]).suffix(64)); next.pending = nil
            try persist(next) // Never mount a popup without its durable local marker.
            available = nil; presented = result.notice; onConsumed?()
        } catch {
            DiagnosticHistory.shared.record("Progression", "Level-up presentation deferred; benefits are retained.",
                scope: DiagnosticHistory.scope(server: saved.server, user: saved.owner))
        }
    }
}
