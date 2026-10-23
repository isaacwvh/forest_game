import Foundation
import Combine

/// One confirmed state owner. Client motion/countdowns never mint visits or tokens.
@MainActor
final class VisitorCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var summary: APIVisitorSummary?
    @Published private(set) var pending: PendingVisitorOperation?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    @Published private(set) var eligible = false
    @Published private(set) var connected = false
    @Published private(set) var recoveryLocked = false
    let userID: UUID
    let installationID: UUID
    private let service: any VisitorServing
    private let journal: any VisitorJournalPersisting
    private let uptime: () -> TimeInterval
    private var receivedUptime: TimeInterval = 0
    private var nextPoll: TimeInterval = 0
    private var worker: Task<Void, Never>?
    private var attached = true
    private var needsRead = true

    init(userID: UUID, installationID: UUID, service: any VisitorServing,
         journal: (any VisitorJournalPersisting)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.userID = userID; self.installationID = installationID
        // Default arguments are evaluated outside this actor on the supported
        // toolchain. Construct the actor-isolated store inside the initializer.
        let resolvedJournal = journal ?? VisitorJournalStore()
        self.service = service; self.journal = resolvedJournal; self.uptime = uptime
        do { pending = try resolvedJournal.load(server: service.serverID, user: userID); try pending?.validate() }
        catch { recoveryLocked = true; message = "The saved visitor request needs attention. It has been retained." }
    }

    var serverNow: Date? { summary.map { $0.serverTime.addingTimeInterval(max(0, uptime() - receivedUptime)) } }
    var visibleOpportunity: APIVisitorOpportunity? {
        guard attached, eligible, connected, pending == nil,
              let now = serverNow, let session = summary?.session,
              session.installationId == installationID, session.leaseExpiresAt > now else { return nil }
        return summary?.opportunities.first { $0.sessionId == session.sessionId && $0.expiresAt > now }
    }

    func start() {
        guard worker == nil, attached else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    func setEligible(_ value: Bool, reconcile: Bool = true) {
        guard attached else { return }
        guard eligible != value else { return }
        eligible = value; needsRead = true; nextPoll = 0
        if reconcile { Task { [weak self] in await self?.tick(force: true) } }
    }

    func pause() async { eligible = false; nextPoll = 0; await tick(force: true) }

    func deactivate() {
        attached = false; eligible = false; connected = false
        worker?.cancel(); worker = nil
        // An in-flight result remains journalled for this account. The lease bounds
        // server coverage if logout prevents sending the explicit end request.
    }

    func apply(_ value: APIVisitorSummary) {
        guard attached, summary == nil || (summary?.gardenId == value.gardenId && value.version >= (summary?.version ?? 0)) else { return }
        summary = value; receivedUptime = uptime(); connected = true
    }

    private func recover() async throws {
        guard let operation = pending else { return }
        do {
            let (value, reward) = try await service.mutate(operation)
            guard attached else { return }
            apply(value)
            try journal.save(nil, server: service.serverID, user: userID)
            pending = nil
            if let reward = reward {
                message = reward.visits == "0" ? "No whole stored visits to collect yet." :
                    "Welcomed \(reward.visits) · +\(reward.tokens) visitor tokens"
            }
        } catch let error as APIError where (400..<500).contains(error.status) &&
                    ![401, 408, 429].contains(error.status) && error.code != "idempotency_conflict" {
            guard attached else { return }
            try journal.save(nil, server: service.serverID, user: userID)
            pending = nil; needsRead = true; connected = false
            throw error
        }
    }

    private func submit(_ kind: PendingVisitorOperation.Kind, target: UUID? = nil) async throws {
        guard pending == nil, attached else { return }
        let id = UUID()
        let installation = kind == .start || kind == .heartbeat || kind == .end ? installationID : nil
        let body = try ActivityWire.encoder().encode(VisitorMutationBody(requestId: id, installationId: installation))
        let operation = PendingVisitorOperation(id: id, kind: kind, target: target, body: body)
        try journal.save(operation, server: service.serverID, user: userID)
        pending = operation
        try await recover()
    }

    func tick(force: Bool = false) async {
        guard attached, !busy, !recoveryLocked, force || uptime() >= nextPoll else { return }
        busy = true
        defer { busy = false; nextPoll = uptime() + Double(summary?.heartbeatSeconds ?? 10) }
        do {
            try await recover()
            guard attached, pending == nil else { return }
            if needsRead || summary == nil {
                let value = try await service.read()
                guard attached else { return }
                apply(value); needsRead = false
            }
            if eligible {
                if let session = summary?.session, session.leaseExpiresAt > (serverNow ?? .distantFuture) {
                    guard session.installationId == installationID else {
                        message = "Visitors are active on another device. They will resume here after that session ends."
                        needsRead = true; return
                    }
                    try await submit(.heartbeat, target: session.sessionId)
                } else { try await submit(.start) }
            } else if let session = summary?.session, session.installationId == installationID {
                try await submit(.end, target: session.sessionId)
            }
            // Eligibility can change while a start/heartbeat is awaiting its response.
            if attached, !eligible, let session = summary?.session, session.installationId == installationID {
                try await submit(.end, target: session.sessionId)
            }
        } catch {
            guard attached else { return }
            connected = false; needsRead = true
            message = "Visitors paused. \(error.localizedDescription) Retry to confirm any saved request."
        }
    }

    func welcome(_ opportunity: APIVisitorOpportunity) async {
        guard !busy, attached, visibleOpportunity?.id == opportunity.id else { return }
        await reward(.welcome, target: opportunity.id)
    }

    func claim() async {
        guard !busy, attached, connected, pending == nil, (Int64(summary?.claimableVisits ?? "0") ?? 0) > 0 else { return }
        await reward(.claim)
    }

    private func reward(_ kind: PendingVisitorOperation.Kind, target: UUID? = nil) async {
        busy = true
        defer { busy = false }
        do { try await submit(kind, target: target) }
        catch {
            guard attached else { return }
            connected = false; needsRead = true
            message = "Reward not yet confirmed. Retry to recover the saved request."
        }
    }
}
