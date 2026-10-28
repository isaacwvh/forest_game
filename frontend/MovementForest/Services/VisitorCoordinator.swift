import Foundation
import Combine

/// One confirmed state owner. Client motion/countdowns never mint visits or tokens.
@MainActor
final class VisitorCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var summary: APIVisitorSummary?
    @Published private(set) var pending: PendingVisitorOperation?
    @Published private(set) var queuedReward: PendingVisitorOperation?
    @Published private(set) var feedback: GardenFeedback?
    var message: String? { feedback?.text }
    var gardenMessage: String? { feedback?.visibleInGarden == true ? message : nil }
    var needsRecoveryNotice: Bool { gardenMessage != nil || !connected || recoveryLocked }
    private func report(_ text: String, kind: GardenFeedback.Kind = .failure, source: GardenFeedback.Source = .visitorReward) {
        feedback = GardenFeedback(text: text, kind: kind, source: source)
    }
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
    private var receivedServerTime: Date?
    private var nextPoll: TimeInterval = 0
    private var worker: Task<Void, Never>?
    private var attached = true
    private var needsRead = true
    private var lastConnectionIssue: UUID?
    @Published private(set) var confirmedTokenBalance: String?
    @Published private(set) var tokenRewards: [ConfirmedTokenReward] = []
    private var liveRewardIDs = Set<UUID>()
    private var economyVersion: Int64 = -1
    var onWallet: ((String, Int64) -> Void)?
    var tokenBalance: String { confirmedTokenBalance ?? summary?.tokenBalance ?? "0" }

    func applyWallet(_ balance: String, version: Int64) {
        guard attached, version > economyVersion, ExactAmount.integer(balance) != nil else { return }
        economyVersion = version; confirmedTokenBalance = balance; onWallet?(balance, version)
    }

    init(userID: UUID, installationID: UUID, service: any VisitorServing,
         journal: (any VisitorJournalPersisting)? = nil,
         uptime: @escaping () -> TimeInterval = { LifecycleClock.elapsed }) {
        self.userID = userID; self.installationID = installationID
        // Default arguments are evaluated outside this actor on the supported
        // toolchain. Construct the actor-isolated store inside the initializer.
        let resolvedJournal = journal ?? VisitorJournalStore()
        self.service = service; self.journal = resolvedJournal; self.uptime = uptime
        do {
            let saved = try resolvedJournal.load(server: service.serverID, user: userID)
            try saved?.validate()
            pending = saved?.pending; queuedReward = saved?.queuedReward
        }
        catch { recoveryLocked = true; report("The saved visitor request needs attention. It has been retained.", kind: .locked) }
    }

    var serverNow: Date? { receivedServerTime.map { $0.addingTimeInterval(max(0, uptime() - receivedUptime)) } }
    var canRequestReward: Bool {
        attached && connected && !recoveryLocked && queuedReward == nil &&
            ((!busy && pending == nil) || pending?.kind == .heartbeat)
    }
    var canCollect: Bool {
        canRequestReward && (summary.flatMap { ExactAmount.integer($0.claimableVisits) } ?? 0) > 0
    }
    var collecting: Bool { queuedReward?.kind == .claim || pending?.kind == .claim }
    var recoveringRequest: Bool { pending != nil && !busy }
    var confirmingReward: Bool {
        queuedReward != nil || pending?.kind == .welcome || pending?.kind == .claim
    }
    var visibleOpportunities: [APIVisitorOpportunity] {
        guard attached, eligible, connected,
              pending == nil || pending?.kind == .heartbeat || pending?.kind == .welcome || pending?.kind == .claim,
              let now = serverNow, let session = summary?.session,
              session.installationId == installationID, session.leaseExpiresAt > now else { return [] }
        let welcoming = queuedReward?.kind == .welcome ? queuedReward?.target : (pending?.kind == .welcome ? pending?.target : nil)
        return Array((summary?.opportunities ?? []).filter {
            $0.sessionId == session.sessionId && $0.issuedAt <= now && $0.expiresAt > now && $0.id != welcoming
        }.prefix(12))
    }
    var visibleOpportunity: APIVisitorOpportunity? { visibleOpportunities.first }

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
        if !value { clearTokenFeedback() }
        eligible = value; needsRead = true; nextPoll = 0
        if reconcile { Task { [weak self] in await self?.tick(force: true) } }
    }

    func pause() async { clearTokenFeedback(); eligible = false; nextPoll = 0; await tick(force: true) }

    func deactivate() {
        clearTokenFeedback()
        attached = false; eligible = false; connected = false
        worker?.cancel(); worker = nil
        // An in-flight result remains journalled for this account. The lease bounds
        // server coverage if logout prevents sending the explicit end request.
    }

    func apply(_ value: APIVisitorSummary) {
        if let version = value.economyVersion { applyWallet(value.tokenBalance, version: version) }
        guard attached, summary == nil || (summary?.gardenId == value.gardenId && value.version >= (summary?.version ?? 0)) else { return }
        // A replayed receipt can have an old server timestamp. It must never
        // rewind the presentation clock or extend a visitor's remaining life.
        receivedServerTime = max(serverNow ?? value.serverTime, value.serverTime)
        summary = value; receivedUptime = uptime(); connected = true
    }

    private func recover() async throws {
        while let operation = pending {
            do {
                let scope = DiagnosticHistory.scope(server: service.serverID, user: userID)
                DiagnosticHistory.shared.record("Visitors", "sending \(operation.kind.rawValue)", requestID: operation.id.uuidString, scope: scope)
                let (value, reward) = try await service.mutate(operation)
                guard attached else { return }
                apply(value)
                DiagnosticHistory.shared.record("Visitors", "confirmed \(operation.kind.rawValue)", requestID: operation.id.uuidString, scope: scope)
                try persist(VisitorJournalState(pending: queuedReward))
                if let reward = reward {
                    // Only operations initiated in this visible session may celebrate.
                    // Recovered journal entries and ordinary wallet refreshes stay quiet.
                    let live = liveRewardIDs.remove(operation.id) != nil
                    if live, eligible, reward.requestId == operation.id,
                       let amount = ExactAmount.integer(reward.tokens), amount > 0,
                       tokenRewards.count < 4 {
                        tokenRewards.append(.init(id: operation.id, amount: NSDecimalNumber(decimal: amount).stringValue))
                    }
                    report(reward.visits == "0" ? "No whole stored visits to collect yet." :
                        "Welcomed \(reward.visits) · +\(reward.tokens) visitor tokens", kind: .success)
                    DiagnosticHistory.shared.record("Visitors", "reward visits=\(reward.visits) tokens=\(reward.tokens)",
                        requestID: operation.id.uuidString, scope: scope)
                }
            } catch let error as APIError where (400..<500).contains(error.status) &&
                        ![401, 408, 429].contains(error.status) && error.code != "idempotency_conflict" {
                guard attached else { return }
                try persist(VisitorJournalState(pending: queuedReward))
                liveRewardIDs.remove(operation.id)
                needsRead = true; connected = false
                throw error
            }
        }
    }

    private func operation(_ kind: PendingVisitorOperation.Kind, target: UUID?) throws -> PendingVisitorOperation {
        let id = UUID()
        let installation = kind == .start || kind == .heartbeat || kind == .end ? installationID : nil
        let protocolVersion = kind == .start && summary?.arrivalProtocol == 2 ? 2 : nil
        let body = try ActivityWire.encoder().encode(VisitorMutationBody(requestId: id, installationId: installation,
                                                                       arrivalProtocol: protocolVersion))
        return PendingVisitorOperation(id: id, kind: kind, target: target, body: body)
    }

    private func persist(_ state: VisitorJournalState) throws {
        try journal.save(state, server: service.serverID, user: userID)
        pending = state.pending; queuedReward = state.queuedReward
    }

    private func submit(_ kind: PendingVisitorOperation.Kind, target: UUID? = nil) async throws {
        guard pending == nil, attached else { return }
        let request = try operation(kind, target: target)
        try persist(VisitorJournalState(pending: request))
        if eligible && (kind == .welcome || kind == .claim) { liveRewardIDs.insert(request.id) }
        try await recover()
    }

    func finishTokenFeedback(_ id: UUID) {
        tokenRewards.removeAll { $0.id == id }
    }

    func clearTokenFeedback() {
        tokenRewards = []; liveRewardIDs = []
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
                        report("Visitors are active on another device. They will resume here after that session ends.", kind: .information, source: .visitorSession)
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
            if let issue = lastConnectionIssue, feedback?.id == issue { feedback = nil }
            if feedback?.source == .visitorSession { feedback = nil }
            lastConnectionIssue = nil
        } catch {
            guard attached else { return }
            connected = false; needsRead = true
            PlayerMessage.recordFailure("Visitors", error, requestID: pending?.id.uuidString,
                scope: DiagnosticHistory.scope(server: service.serverID, user: userID))
            let issue = "Visitors paused. " + PlayerMessage.failure(error, fallback: "Retry to confirm any saved request.")
            report(issue, source: .visitorConnection); lastConnectionIssue = feedback?.id
            let failure = error as NSError
            LifecycleDiagnostics.event("visitor request failed domain=\(failure.domain) code=\(failure.code)")
        }
    }

    func welcome(_ opportunity: APIVisitorOpportunity) async {
        guard canRequestReward, visibleOpportunities.contains(where: { $0.id == opportunity.id }) else { return }
        await reward(.welcome, target: opportunity.id)
    }

    func claim() async {
        guard canCollect else { return }
        await reward(.claim)
    }

    private func reward(_ kind: PendingVisitorOperation.Kind, target: UUID? = nil) async {
        if pending?.kind == .heartbeat {
            do {
                let request = try operation(kind, target: target)
                try persist(VisitorJournalState(pending: pending, queuedReward: request))
                if eligible { liveRewardIDs.insert(request.id) }
                if !busy { await tick(force: true) }
            } catch {
                PlayerMessage.recordFailure("Visitors", error,
                    scope: DiagnosticHistory.scope(server: service.serverID, user: userID))
                report("The visitor tap could not be saved. Please try again.")
            }
            return
        }
        busy = true
        defer { busy = false }
        do { try await submit(kind, target: target) }
        catch {
            guard attached else { return }
            connected = false; needsRead = true
            PlayerMessage.recordFailure("Visitors", error, requestID: pending?.id.uuidString,
                scope: DiagnosticHistory.scope(server: service.serverID, user: userID))
            report("Reward not yet confirmed. Retry to recover the saved request.", kind: .uncertain)
        }
    }
}
