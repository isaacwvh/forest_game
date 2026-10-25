import SwiftUI

struct ConnectedActivityScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var store: ActivityStore
    var body: some View {
        if let sync = connection.activitySync {
            ActivitySyncScreen(sync: sync, health: store)
        } else {
            ActivityScreen(store: store)
        }
    }
}

struct ActivitySyncScreen: View {
    @ObservedObject var sync: ActivitySyncCoordinator
    @ObservedObject var health: ActivityStore
    @State private var showingConsent = false
    @State private var replacing = false
    var body: some View {
        List {
            Section("Movement grows your planted forest") {
                Text("Each planted copy converts its supported activities into water. Plants in storage keep their progress and do not grow.")
                Toggle("Sync activity with my garden", isOn: Binding(get: { sync.enabled }, set: { value in
                    if value { showingConsent = true }
                    else { Task { await sync.setEnabled(false) } }
                })).disabled(sync.busy || sync.recoveryLocked || !sync.canUpload)
                    .accessibilityIdentifier("sync.enabled")
                if sync.enabled && !sync.includesOptionalActivity {
                    Text("Your existing permission uploads steps only.")
                    Button("Enable optional quantities and workouts") { showingConsent = true }
                }
                Text("With full activity sync enabled, daily steps, distance, active energy, flights and recorded workout identity, type, source, timestamps and eligible segments are queued on this iPhone and uploaded for growth. You can pause future uploads here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sync status") {
                if sync.busy { ProgressView("Confirming activity…") }
                Text(sync.message).accessibilityIdentifier("sync.status")
                if let status = sync.status {
                    DetailRow(title: "Game timezone", value: status.gameTimezone)
                    DetailRow(title: "Last confirmed sync", value: status.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet synced")
                    DetailRow(title: "Lifetime eligible steps", value: status.activitySteps)
                    DetailRow(title: "First maturities", value: String(status.firstMaturityCount))
                    if let device = status.device {
                        DetailRow(title: "Activity baseline", value: device.ready ? "\(device.baselineDate ?? "") · metrics establish eligibility separately" : "Waiting for readable current-day activity")
                    }
                }
                DetailRow(title: "Saved requests awaiting confirmation", value: String(sync.pendingCount))
                Button("Sync now") { Task { _ = await sync.synchronize() } }
                    .disabled(sync.busy || sync.recoveryLocked).accessibilityIdentifier("sync.now")
                if sync.otherDeviceActive {
                    Button("Use this iPhone for activity") { replacing = true }
                        .disabled(sync.busy || !sync.enabled).accessibilityIdentifier("sync.replace")
                }
                if sync.recoveryLocked {
                    Text("Pending request IDs are available below for recovery. Reconnect after resolving the journal or receipt conflict.")
                        .font(.footnote)
                }
                #if DEBUG
                if !sync.requestIDs.isEmpty {
                    DisclosureGroup("Pending request IDs") {
                        ForEach(sync.requestIDs, id: \.self) { Text($0.uuidString).font(.caption).textSelection(.enabled) }
                    }
                }
                #endif
            }
            if !sync.recaps.isEmpty {
                Section("Confirmed growth") {
                    ForEach(sync.recaps) { recap in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(recap.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            ForEach(recap.payload.plants) { plant in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("+\(ExactAmount.water(plant.awardedGrowthMicroUnits)) water")
                                    if let bonus = plant.skillBonusGrowthMicroUnits,
                                       let amount = ExactAmount.integer(bonus), amount > 0 {
                                        Text("Includes +\(ExactAmount.water(bonus)) from garden skills")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(plant.beforeStage == plant.afterStage ? plant.afterStage.title :
                                         "\(plant.beforeStage.title) → \(plant.afterStage.title)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Plant \(plant.plantId.uuidString.prefix(8))").font(.caption).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                            }
                        }.padding(.vertical, 4)
                    }
                    Button("Done / skip recap") { Task { await sync.dismissRecaps() } }
                        .disabled(sync.busy).accessibilityIdentifier("sync.recapDone")
                    Text("Growth is already saved. Viewing or skipping this recap never grants another reward.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink("Health activity on this iPhone") { ActivityScreen(store: health) }
                Text("Your first readable current-day total establishes a baseline and earns no historical growth. Later increases grow the plants present when the backend accepts them. Activity earns no visitor tokens or seed tickets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Activity")
            .refreshable { _ = await sync.synchronize() }
            .alert("Upload activity to your garden?", isPresented: $showingConsent) {
                Button("Enable activity sync") { Task { await sync.setEnabled(true) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Daily quantities and recorded workout details will be saved locally for reliable retries and sent to your backend to calculate growth. Manually entered workouts do not qualify. Each new metric starts with a baseline; old activity earns no historical reward. Health access is optional.")
            }
            .alert("Replace the reporting iPhone?", isPresented: $replacing) {
                Button("Use this iPhone", role: .destructive) { Task { _ = await sync.synchronize(replacingDevice: true) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Sync the old iPhone first if possible. This takes a fresh baseline; unsubmitted activity from the old device may not earn growth. Previously confirmed growth is preserved.")
            }
    }
}

struct GardenActivityStatus: View {
    @ObservedObject var sync: ActivitySyncCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sync.busy { ProgressView("Syncing activity…") }
            Text(sync.message).font(.caption)
            if !sync.recaps.isEmpty {
                Text("New confirmed growth · Open Activity for your recap").font(.caption).fontWeight(.semibold)
            }
        }
    }
}
