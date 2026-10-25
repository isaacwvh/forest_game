import Foundation
import Combine

@MainActor
final class ActivitySyncCoordinator: ObservableObject {
    let id = UUID()
    @Published private(set) var enabled = false
    @Published private(set) var includesOptionalActivity = false
    @Published private(set) var busy = false
    @Published private(set) var message = "Activity sync is off."
    @Published private(set) var status: APIActivityStatus?
    @Published private(set) var pendingCount = 0
    @Published private(set) var recaps: [APIRewardRecap] = []
    @Published private(set) var recoveryLocked = false
    let installationID: UUID
    private let editor: GardenEditorStore
    private let health: ActivityStore
    private var service: any ActivityServing
    private let journal: any ActivityJournalPersisting
    private var saved = ActivityJournalState()
    private var running: Task<Bool, Never>?
    private var runID: UUID?
    private var active = true

    init(editor: GardenEditorStore, health: ActivityStore, service: any ActivityServing,
         installationID: UUID, journal: (any ActivityJournalPersisting)? = nil) {
        self.editor = editor; self.health = health; self.service = service
        let resolvedJournal = journal ?? ActivityJournalStore()
        self.installationID = installationID; self.journal = resolvedJournal
        do {
            saved = try resolvedJournal.load(server: service.serverID, user: editor.profile.userId) ?? ActivityJournalState()
            enabled = saved.enabled; status = saved.status; pendingCount = saved.operations.count
            includesOptionalActivity = saved.expandedInputsEnabled == true
            message = enabled ? "Ready to reconcile activity." : "Activity sync is off."
        } catch {
            recoveryLocked = true
            message = "The saved activity queue could not be read. Sync and editing are paused to protect pending requests."
        }
        updateEditingGate()
        if enabled { observeHealthChanges() }
    }

    var otherDeviceActive: Bool {
        status?.device.map { $0.installationId != installationID } ?? false
    }
    var canUpload: Bool { !health.provider.isFixture && health.provider.isAvailable }
    var requestIDs: [UUID] { saved.operations.map(\.id) }

    func deactivate() {
        active = false
        editor.prepareMembershipChange = nil; editor.reconcileActivity = nil
    }

    private func save(_ proposed: ActivityJournalState) throws {
        try journal.save(proposed, server: service.serverID, user: editor.profile.userId)
        saved = proposed; enabled = saved.enabled; status = saved.status; pendingCount = saved.operations.count
        includesOptionalActivity = saved.expandedInputsEnabled == true
        updateEditingGate()
    }
    private func updateEditingGate() {
        editor.activityBlocked = recoveryLocked || !saved.operations.isEmpty || (enabled && otherDeviceActive)
    }

    func setEnabled(_ value: Bool) async {
        guard active, !busy, !recoveryLocked else { return }
        guard !value || canUpload else { message = "Sample or unavailable Health data cannot be uploaded."; return }
        do {
            var next = saved; next.enabled = value
            if value { next.expandedInputsEnabled = true }
            try save(next)
            if value {
                await health.connect()
                observeHealthChanges()
                _ = await synchronize()
            } else {
                message = pendingCount > 0 ? "Uploads paused. Re-enable sync to resolve saved requests before editing." : "Activity sync is off."
            }
        } catch { message = "The activity preference could not be saved. Nothing was sent." }
    }

    private func observeHealthChanges() {
        health.provider.observeChanges { [weak self] in
            guard let self = self, self.active, self.enabled else { return }
            _ = await self.synchronize()
        }
    }

    /// Coalesces foreground/manual calls. A membership preflight waits for the
    /// existing pass, then takes a fresh observation before allowing the edit.
    @discardableResult
    func synchronize(beforeMembershipChange: Bool = false, replacingDevice: Bool = false) async -> Bool {
        guard active, !recoveryLocked, !(busy && running == nil) else { return false }
        if let running = running {
            let result = await running.value
            if !beforeMembershipChange { return result }
            guard result, active else { return false }
        }
        let id = UUID(); runID = id
        let task = Task { await self.run(replacingDevice: replacingDevice) }
        running = task
        let result = await task.value
        if runID == id { running = nil; runID = nil }
        return result
    }

    private func run(replacingDevice: Bool) async -> Bool {
        guard active else { return false }
        busy = true
        defer { busy = false; updateEditingGate() }
        if editor.pending != nil { await editor.retryPending() }
        guard editor.pending == nil, editor.beginActivityOperation() else {
            message = "Finish confirming the saved garden edit before syncing activity."
            return false
        }
        defer { editor.endActivityOperation() }
        do {
            if !saved.operations.isEmpty {
                guard enabled || saved.operations.allSatisfy({ $0.kind == .acknowledgement }) else {
                    message = "Saved uploads are paused. Re-enable activity sync to recover them."
                    return false
                }
                try await drain()
            }
            try await refreshStatus()
            guard active else { return false }
            if enabled {
                guard canUpload, health.hasRequestedAccess else {
                    message = "Connect Apple Health before syncing steps."
                    await editor.refresh(); return false
                }
                if otherDeviceActive && !replacingDevice {
                    message = "Another iPhone reports activity for this account. Choose Use this iPhone to replace it."
                    await editor.refresh(); try await loadRecaps(); return false
                }
                let observation = try await observe()
                if status?.device == nil || replacingDevice {
                    var request = ActivityEnrolmentRequest(requestId: UUID(), installationId: installationID,
                                                          observedAt: observation.observedAt,
                                                          expectedDeviceId: replacingDevice ? status?.device?.deviceId : nil,
                                                          steps: observation.days.last?.steps)
                    if includesOptionalActivity {
                        request.walkingRunningDistanceMetres = observation.days.last?.walkingRunningDistanceMetres
                        request.activeEnergyKcal = observation.days.last?.activeEnergyKcal
                        request.flightsClimbed = observation.days.last?.flightsClimbed
                        request.workoutsAvailable = observation.workoutsAvailable ? true : nil
                    }
                    try enqueue(.init(id: request.requestId, kind: .enrolment,
                                      body: ActivityWire.encoder().encode(request), recapID: nil))
                    try await drain()
                    try await refreshStatus()
                } else {
                    try enqueueSync(observation)
                    try await drain()
                    try await refreshStatus()
                }
                if status?.device?.ready != true {
                    message = "Waiting for readable current-day activity to establish a baseline. No historical growth was awarded."
                } else if observation.days.last?.steps == nil {
                    message = "Sync confirmed, but today's steps are unavailable. Existing growth is preserved; unlock your iPhone and review Health access."
                } else { message = "Activity confirmed. New movement grows plants through their pinned activity multipliers." }
                if observation.omittedWorkouts > 0 {
                    message += " Some workout records could not be uploaded; other readable activity was synced."
                }
            } else { message = "Activity sync is off. Your confirmed garden is up to date." }
            await editor.refresh()
            try await loadRecaps()
            return !editor.showingCached && editor.state == .ready
        } catch {
            guard active else { return false }
            let issue = error as? APIError
            if issue?.status == 401 {
                message = "Sign in again to the same account; saved requests will resume unchanged."
            } else if issue?.code == "idempotency_conflict" {
                recoveryLocked = true
                message = "A saved activity request conflicts with its receipt. Recovery is paused; inspect the pending request ID."
            } else if issue?.code == "inactive_activity_device" || issue?.code == "stale_activity_device" || issue?.code == "activity_device_mismatch" {
                message = "The reporting device changed. Refresh, then explicitly choose which iPhone reports activity."
            } else if let issue = issue {
                message = "Activity was not confirmed. \(issue.message)"
            } else if let local = error as? ForestError {
                message = "Activity was not confirmed. \(local.localizedDescription) Saved requests are retained."
            } else if error is DecodingError {
                message = "The server response could not be verified. The original request is retained; reconnect before retrying."
            } else if (error as NSError).domain == NSCocoaErrorDomain {
                message = "Activity data could not be saved on this iPhone. Check available storage and retry; existing requests are retained."
            } else {
                message = "Offline or confirmation interrupted. Saved requests will retry unchanged when you reconnect."
                await captureOfflineObservation()
            }
            await editor.refresh()
            // A recovered enrolment/sync receipt may describe an old device epoch.
            // Refresh status independently even after a definitive queue rejection.
            if issue != nil { try? await refreshStatus() }
            return false
        }
    }

    private func refreshStatus() async throws {
        let value = try await service.activityStatus()
        guard active else { throw CancellationError() }
        guard value.gameTimezone == editor.profile.gameTimezone, TimeZone(identifier: value.gameTimezone) != nil,
              value.supportedMetrics.contains("steps"), (1...7).contains(value.reconciliationDays),
              value.queuedUploadMaxAgeDays > 0 else {
            throw ForestError.invalidData("The account's activity policy is unavailable. Reconnect before uploading.")
        }
        var next = saved; next.status = value; try save(next)
    }

    private struct Observation {
        let observedAt: Date
        let days: [ActivityDayUpload]
        var workouts: [WorkoutUpload] = []
        var workoutsAvailable = false
        var omittedWorkouts = 0
    }
    private func observe() async throws -> Observation {
        guard let status = status, let timeZone = TimeZone(identifier: status.gameTimezone) else {
            throw ForestError.invalidData("Load the account's game timezone first.")
        }
        let extended = includesOptionalActivity && status.supportedMetrics.count > 1
        let report = await health.readForUpload(timeZone: timeZone, includingOptional: extended)
        guard active, !report.isFixture, report.timeZoneIdentifier == timeZone.identifier else {
            throw ForestError.invalidData("This activity observation cannot be uploaded.")
        }
        let days = try report.days.suffix(status.reconciliationDays).map {
            var day = ActivityDayUpload(gameDate: ActivityWire.gameDate($0.start, timeZone: timeZone),
                                        steps: try ActivityWire.steps(report.stepsIssue == nil ? $0.steps : nil))
            if extended {
                day.walkingRunningDistanceMetres = ActivityWire.quantity($0.walkingRunningDistanceMetres)
                day.activeEnergyKcal = ActivityWire.quantity($0.activeEnergyKcal, maximum: 9_999_999)
                if let flights = $0.flightsClimbed, flights.isFinite, flights >= 0, flights <= 1_000_000 {
                    day.flightsClimbed = Int64(flights.rounded(.down))
                }
            }
            return day
        }
        guard !days.isEmpty else { throw ForestError.invalidData("There is no current-day observation to upload.") }
        let readableWorkouts = extended && report.workoutsIssue == nil
        let workouts = readableWorkouts ? report.workouts.compactMap(ActivityWire.workout) : []
        return Observation(observedAt: report.observedAt, days: days, workouts: workouts,
                           workoutsAvailable: readableWorkouts,
                           omittedWorkouts: readableWorkouts ? report.workouts.count - workouts.count : 0)
    }

    private func enqueueSync(_ observation: Observation) throws {
        guard let device = status?.device, device.installationId == installationID else {
            throw ForestError.invalidData("This iPhone is not the active activity device.")
        }
        let days = device.ready ? observation.days.filter { $0.gameDate >= (device.baselineDate ?? "9999") } :
            Array(observation.days.suffix(1))
        guard !days.isEmpty else { return }
        // Never rewrite queued bytes. Identical cumulative totals already in the
        // queue do not need another request merely because the app foregrounded.
        var chunks: [[WorkoutUpload]] = [[]]
        var segmentCount = 0
        for workout in observation.workouts {
            if chunks[chunks.count - 1].count >= 500 || segmentCount + workout.segments.count > 2000 {
                chunks.append([]); segmentCount = 0
            }
            chunks[chunks.count - 1].append(workout)
            segmentCount += workout.segments.count
        }
        for chunk in chunks {
            if let last = saved.operations.last, last.kind == .sync,
               let request = try? ActivityWire.decoder().decode(ActivitySyncRequest.self, from: last.body),
               request.deviceId == device.deviceId, request.days == days,
               (request.workouts ?? []) == chunk,
               (request.workoutsAvailable ?? false) == observation.workoutsAvailable { continue }
            var request = ActivitySyncRequest(requestId: UUID(), installationId: installationID,
                                              deviceId: device.deviceId, observedAt: observation.observedAt, days: days)
            request.workoutsAvailable = observation.workoutsAvailable ? true : nil
            request.workouts = chunk.isEmpty ? nil : chunk
            try enqueue(.init(id: request.requestId, kind: .sync, body: ActivityWire.encoder().encode(request), recapID: nil))
        }
    }

    private func enqueue(_ operation: PendingActivityOperation) throws {
        guard active, saved.operations.count < 256 else {
            throw ForestError.invalidData("The activity queue is full. Reconnect to confirm saved observations.")
        }
        var next = saved; next.operations.append(operation); try save(next)
    }

    private func captureOfflineObservation() async {
        guard active, enabled, canUpload, health.hasRequestedAccess, let device = status?.device,
              device.ready, device.installationId == installationID else { return }
        do { try enqueueSync(await observe()) }
        catch { message += " A new observation could not be saved; existing requests are retained." }
    }

    private func drain(acknowledgementsOnly: Bool = false) async throws {
        while let operation = saved.operations.first {
            if acknowledgementsOnly && operation.kind != .acknowledgement { return }
            guard active else { throw CancellationError() }
            do {
                switch operation.kind {
                case .enrolment:
                    let result = try await service.enrol(body: operation.body)
                    guard active else { throw CancellationError() }
                    guard result.requestId == operation.id else { throw ForestError.invalidData("Unexpected enrolment receipt.") }
                case .sync:
                    let result = try await service.sync(body: operation.body)
                    guard active else { throw CancellationError() }
                    guard result.requestId == operation.id, result.garden.gardenId == editor.confirmed?.gardenId else {
                        throw ForestError.invalidData("Unexpected activity receipt.")
                    }
                    try editor.applyConfirmed(result.garden, at: result.acceptedAt)
                case .acknowledgement:
                    guard let recap = operation.recapID else { throw ForestError.invalidData("Invalid recap request.") }
                    let result = try await service.acknowledge(recap: recap, body: operation.body)
                    guard active else { throw CancellationError() }
                    guard result.requestId == operation.id, result.recapId == recap else {
                        throw ForestError.invalidData("Unexpected recap receipt.")
                    }
                }
            } catch let error as APIError where (400..<500).contains(error.status) && ![401, 408, 429].contains(error.status) && error.code != "idempotency_conflict" {
                // This request definitively did not commit. Record the rejection
                // before removing it; never change input under its existing ID.
                var next = saved
                next.lastRejectedRequest = operation.id; next.lastRejectionCode = error.code
                next.operations.removeFirst(); try save(next)
                throw error
            }
            guard active else { throw CancellationError() }
            var next = saved; next.operations.removeFirst()
            if let recap = operation.recapID { next.dismissedRecaps.removeAll { $0 == recap } }
            try save(next)
        }
    }

    private func loadRecaps() async throws {
        var all: [APIRewardRecap] = [], cursor: UUID?
        var seen = Set<UUID>()
        var cursors = Set<UUID>()
        repeat {
            let page = try await service.recaps(after: cursor)
            guard active else { throw CancellationError() }
            all += page.recaps.filter { seen.insert($0.id).inserted && !saved.dismissedRecaps.contains($0.id) }
            if let next = page.nextCursor, !cursors.insert(next).inserted {
                throw ForestError.invalidData("Recap pagination did not advance.")
            }
            cursor = page.nextCursor
        } while cursor != nil
        recaps = all.sorted { $0.createdAt < $1.createdAt }
    }

    func dismissRecaps(ids: Set<UUID>? = nil) async {
        guard active, !recoveryLocked, !recaps.isEmpty else { return }
        let canDrain = !busy && running == nil
        if canDrain { busy = true }
        defer { if canDrain { busy = false }; updateEditingGate() }
        do {
            var next = saved
            let available = max(0, 256 - next.operations.count)
            guard available > 0 else {
                message = "Confirm saved requests before acknowledging more recaps."
                return
            }
            for recap in recaps.filter({ ids?.contains($0.id) ?? true }).prefix(available) where !next.dismissedRecaps.contains(recap.id) {
                let id = UUID()
                next.operations.append(.init(id: id, kind: .acknowledgement,
                                             body: try ActivityWire.encoder().encode(RequestIdentity(requestId: id)), recapID: recap.id))
                next.dismissedRecaps.append(recap.id)
            }
            try save(next)
            recaps.removeAll { saved.dismissedRecaps.contains($0.id) }
            guard canDrain else {
                message = "Recap acknowledged on this iPhone. Confirmation will retry with saved activity."
                return
            }
            // Presentation can only acknowledge already committed events. Do
            // not capture or submit new activity as a side effect of dismissal.
            try await drain(acknowledgementsOnly: true)
            try await loadRecaps()
            message = saved.operations.isEmpty ? "Recap acknowledged. Your growth was already saved." :
                "Recap acknowledgement is queued behind saved activity. Confirm it with Sync now."
        } catch let error as APIError where error.code == "idempotency_conflict" {
            recoveryLocked = true
            message = "The recap request conflicts with a server receipt. Recovery is paused; inspect the pending request ID."
        } catch {
            message = "Recap acknowledgement is not confirmed. Any saved request will retry unchanged; your growth is safe."
        }
    }
}
