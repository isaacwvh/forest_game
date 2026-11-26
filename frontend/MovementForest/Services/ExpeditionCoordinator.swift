import Foundation
import Combine

/// Evidence has its own durable queue; it never occupies the garden-growth queue.
@MainActor
final class ExpeditionCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var status: ExpeditionStatus?
    @Published private(set) var archived: [ExpeditionRun] = []
    @Published private(set) var archiveCursor: UUID?
    @Published private(set) var busy = false
    @Published private(set) var recovering = false
    @Published private(set) var cached = false
    @Published private(set) var message: String?
    @Published private(set) var recoveryLocked = false
    private let client: APIClient
    private let user: UUID
    private let disk: AccountDiskStore
    private let health: ActivityStore
    private weak var activity: ActivitySyncCoordinator?
    private weak var collection: CollectionCoordinator?
    private var journal = ExpeditionJournal()
    private var active = true
    private var anchorUptime = ProcessInfo.processInfo.systemUptime
    private var anchorServer = Date()

    init(client: APIClient, user: UUID, disk: AccountDiskStore, health: ActivityStore,
         activity: ActivitySyncCoordinator, collection: CollectionCoordinator?) {
        self.client = client; self.user = user; self.disk = disk; self.health = health
        self.activity = activity; self.collection = collection
        do {
            journal = try disk.load(ExpeditionJournal.self, kind: "expeditions", server: client.baseURL.absoluteString, user: user) ?? ExpeditionJournal()
            _ = try journal.status?.current?.validated()
            status = journal.status; cached = status != nil
            if let confirmed = collection?.state.result?.entitlementId {
                var ids = Set(journal.claimedEntitlements ?? []); ids.insert(confirmed)
                journal.claimedEntitlements = Array(ids)
            }
            if var restored = status {
                restored.current = restored.current?.confirmingClaims(Set(journal.claimedEntitlements ?? []))
                restored.previous = restored.previous.map { $0.confirmingClaims(Set(journal.claimedEntitlements ?? [])) }
                status = restored
            }
        } catch {
            recoveryLocked = true
            message = "Saved expedition data could not be read. Reconnect before recovering rewards."
        }
    }
    var serverNow: Date { anchorServer.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime - anchorUptime)) }
    var canClaim: Bool { active && !cached && !recoveryLocked && collection?.canMutate == true }
    var pendingClaim: Bool { collection?.state.pending?.kind == .expeditionClaim }
    func deactivate() { active = false }
    private func save(_ proposed: ExpeditionJournal) throws {
        try disk.save(proposed, kind: "expeditions", server: client.baseURL.absoluteString, user: user)
        journal = proposed
    }
    func refresh() async {
        guard active, !busy, !recoveryLocked else { return }
        busy = true
        defer { busy = false }
        do {
            if collection?.tokenBalance == nil { await collection?.refresh(scope: .home) }
            try await loadStatus()
        }
        catch {
            guard active else { return }
            cached = status != nil
            message = "Expedition could not refresh. Saved progress remains available."
        }
    }
    private func loadStatus(retryOlder: Bool = false) async throws {
        try retainConfirmedReceipt()
        var incoming: ExpeditionStatus = try await client.request("v1/me/expeditions/current",
            query: retryOlder ? [URLQueryItem(name: "retryOlder", value: "true")] : [])
        guard active else { return }
        _ = try incoming.current?.validated()
        for run in incoming.previous { _ = try run.validated() }
        let confirmed = Set(journal.claimedEntitlements ?? [])
        incoming.current = incoming.current?.confirmingClaims(confirmed)
        incoming.previous = incoming.previous.map { $0.confirmingClaims(confirmed) }
        if let known = status?.current, let received = incoming.current,
           known.runId == received.runId, known.progressVersion > received.progressVersion { return }
        var proposed = journal; proposed.status = incoming; proposed.confirmedAt = Date()
        try save(proposed)
        status = incoming; cached = false; message = nil
        anchorServer = incoming.serverNow; anchorUptime = ProcessInfo.processInfo.systemUptime
    }
    func recoverEvidence(retryOlder: Bool = false) async {
        guard active, !recovering, !recoveryLocked, health.hasRequestedAccess,
              let activity = activity, activity.enabled,
              let device = activity.status?.device, device.ready,
              let installation = try? InstallationIdentity.load(disk: disk),
              device.installationId == installation else { return }
        recovering = true
        defer { recovering = false }
        do {
            try await drainEvidence()
            try await loadStatus(retryOlder: retryOlder)
            guard active else { return }
            let runs = (status?.previous ?? []) + (status?.current.map { [$0] } ?? [])
            for run in runs {
                let ranges = run.coverage
                for offset in stride(from: 0, to: ranges.count, by: 7) {
                    guard active, !Task.isCancelled else { return }
                    let batch = Array(ranges[offset..<min(offset + 7, ranges.count)])
                    let observedAt = Date()
                    let report = try await health.provider.readExpeditionEvidence(ranges: batch, now: observedAt)
                    guard active else { return }
                    // A query may contain more than 500 workouts or 2,000 segments.
                    // Only the last durable chunk acknowledges workout coverage.
                    var chunks: [[WorkoutUpload]] = [[]]
                    var segments = 0
                    for workout in report.workouts {
                        if chunks[chunks.count - 1].count >= 500 || segments + workout.segments.count > 2000 {
                            chunks.append([]); segments = 0
                        }
                        chunks[chunks.count - 1].append(workout); segments += workout.segments.count
                    }
                    var proposed = journal
                    for (index, workouts) in chunks.enumerated() {
                        var days = report.days
                        if index != chunks.count - 1 {
                            for i in days.indices { days[i].workoutsComplete = false }
                        }
                        guard days.contains(where: { $0.steps != nil || $0.workoutsComplete }) || !workouts.isEmpty else { continue }
                        let id = UUID()
                        let body = ExpeditionEvidenceBody(schemaVersion: 1, requestId: id, deviceId: device.deviceId,
                            installationId: installation, observedAt: observedAt, days: days, workouts: workouts)
                        proposed.operations.append(PendingExpeditionEvidence(id: id, runID: run.runId,
                            body: try ActivityWire.encoder().encode(body)))
                    }
                    try save(proposed)
                    try await drainEvidence()
                }
            }
            try await loadStatus()
        } catch {
            guard active else { return }
            message = "Some expedition activity still needs recovery. Unlock your iPhone and retry. Saved uploads are retained."
        }
    }
    private func drainEvidence() async throws {
        while active, let pending = journal.operations.first {
            let body = try ActivityWire.decoder().decode(ExpeditionEvidenceBody.self, from: pending.body)
            guard body.requestId == pending.id else { throw ForestError.invalidData("Saved evidence identity differs.") }
            let result: ExpeditionEvidenceResult
            do {
                result = try await client.request("v1/me/expeditions/\(pending.runID.uuidString)/evidence", method: "POST", body: pending.body)
            } catch let error as APIError where error.code == "expedition_evidence_expired" || error.code == "inactive_activity_device" {
                // Replay is checked before either rejection on the server, so this
                // confirms the saved operation did not commit. It cannot block a
                // new month/device forever or be retried under a different UUID.
                guard active else { return }
                var proposed = journal; proposed.operations.removeFirst(); try save(proposed)
                message = error.message
                continue
            }
            guard active else { return }
            guard result.requestId == pending.id, result.runId == pending.runID, result.progressVersion >= 0 else {
                throw ForestError.invalidData("The evidence receipt could not be verified.")
            }
            var proposed = journal; proposed.operations.removeFirst(); try save(proposed)
        }
    }
    func claim(_ entitlement: ExpeditionEntitlement, run: ExpeditionRun) async {
        guard canClaim, !entitlement.claimed else { return }
        await collection?.claimExpedition(run: run.runId, entitlement: entitlement.id)
        guard active else { return }
        let confirmed = collection?.state.pending == nil && collection?.state.result?.entitlementId == entitlement.id
        if confirmed {
            do { try retainConfirmedReceipt() }
            catch {
                recoveryLocked = true
                message = "Reward collected. Its receipt is saved; reconnect before collecting more rewards."
                return
            }
        }
        await refresh()
        await loadArchive()
        if confirmed && cached { message = "Reward collected. Connect to refresh expedition progress." }
        if collection?.state.pending != nil || collection?.message != nil && collection?.state.result?.entitlementId != entitlement.id {
            message = collection?.message
        }
    }
    private func retainConfirmedReceipt() throws {
        guard let identifier = collection?.state.result?.entitlementId else { return }
        var identifiers = Set(journal.claimedEntitlements ?? [])
        guard identifiers.insert(identifier).inserted else { return }
        var proposed = journal
        proposed.claimedEntitlements = Array(identifiers)
        if var updated = proposed.status {
            updated.current = updated.current?.confirmingClaims(identifiers)
            updated.previous = updated.previous.map { $0.confirmingClaims(identifiers) }
            proposed.status = updated
        }
        // The shared collection journal already holds the verified receipt.
        // Keep the visible confirmed state even if this secondary cache fails.
        status = proposed.status
        archived = archived.map { $0.confirmingClaims(identifiers) }
        try save(proposed)
    }
    func retryClaim() async {
        await collection?.refresh(scope: .home)
        do { try retainConfirmedReceipt() }
        catch { recoveryLocked = true; message = "The confirmed receipt is saved. Reconnect before collecting more rewards."; return }
        await refresh()
    }
    func loadArchive(more: Bool = false) async {
        guard active else { return }
        do {
            let query = more ? archiveCursor.map { [URLQueryItem(name: "before", value: $0.uuidString)] } ?? [] : []
            let result: ExpeditionArchive = try await client.request("v1/me/expeditions", query: query)
            guard active else { return }
            for run in result.runs { _ = try run.validated() }
            let confirmed = result.runs.map { $0.confirmingClaims(Set(journal.claimedEntitlements ?? [])) }
            archived = more ? archived + confirmed : confirmed
            archiveCursor = result.nextCursor
        } catch { if active { message = "Earlier expeditions could not load. Try again." } }
    }
}
