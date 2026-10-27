import SwiftUI

struct ConnectedActivityScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var store: ActivityStore
    var body: some View {
        if let sync = connection.activitySync {
            ActivitySyncScreen(sync: sync, health: store, plants: (connection.editor?.confirmed?.plants ?? []) + (connection.editor?.inventory ?? []),
                               catalogue: connection.editor?.catalogue)
        } else {
            ActivityScreen(store: store)
        }
    }
}

struct ActivitySyncScreen: View {
    @ObservedObject var sync: ActivitySyncCoordinator
    @ObservedObject var health: ActivityStore
    var plants: [APIOwnedPlant] = []
    var catalogue: APICatalogue? = nil
    @State private var showingConsent = false
    @State private var replacing = false
    var body: some View {
        List {
            Section("Sync status") {
                if sync.busy { ProgressView("Confirming activity…") }
                Text(sync.message).accessibilityIdentifier("sync.status")
                if let status = sync.status {
                    DetailRow(title: "Last confirmed sync", value: status.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet synced")
                    DisclosureGroup("Sync details") {
                        DetailRow(title: "Game timezone", value: status.gameTimezone)
                        DetailRow(title: "Lifetime eligible steps", value: status.activitySteps)
                        DetailRow(title: "First maturities", value: String(status.firstMaturityCount))
                    }
                }
                if sync.pendingCount > 0 {
                    DetailRow(title: "Awaiting confirmation", value: String(sync.pendingCount))
                }
                Button("Sync now") { Task { _ = await sync.synchronize() } }
                    .disabled(sync.busy || sync.recoveryLocked).accessibilityIdentifier("sync.now")
                if sync.otherDeviceActive {
                    Button("Use this iPhone for activity") { replacing = true }
                        .disabled(sync.busy || !sync.enabled).accessibilityIdentifier("sync.replace")
                }
                if sync.recoveryLocked {
                    Text("Sync is paused to protect a saved update. Sign in again through Settings → Account and sign-in to reconnect. Your saved requests are retained.")
                        .font(.footnote)
                }

            }
            Section("Activity sync") {
                Toggle("Sync activity with my garden", isOn: Binding(get: { sync.enabled }, set: { value in
                    if value { showingConsent = true }
                    else { Task { await sync.setEnabled(false) } }
                })).disabled(sync.busy || sync.recoveryLocked || !sync.canUpload)
                    .accessibilityIdentifier("sync.enabled")
                if sync.enabled && !sync.includesOptionalActivity {
                    Text("Steps-only sync").font(.caption).foregroundStyle(.secondary)
                    Button("Enable optional quantities and workouts") { showingConsent = true }
                }
                DisclosureGroup("About activity sync") {
                    Text("Supported activity waters planted copies. Stored plants keep their progress without growing. Only new activity after enabling sync earns growth; activity does not award visitor tokens.")
                    Text("Full sync queues daily steps, distance, active energy, flights and recorded workout identity, type, source, timestamps and eligible segments on this iPhone, then uploads them for growth. Pause future uploads with the switch above.")
                }
            }
            if !sync.recaps.isEmpty {
                Section("Confirmed growth") {
                    ForEach(sync.recaps) { recap in
                        DisclosureGroup(recap.createdAt.formatted(date: .abbreviated, time: .shortened)) {
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
                                    PlantNameText(OwnedCopyLabel.title(plant.plantId, in: plants),
                                        rarity: plants.first { $0.id == plant.plantId }.flatMap { catalogue?.rarity(for: $0.speciesId) }).font(.caption)
                                }.accessibilityElement(children: .combine)
                            }
                        }.padding(.vertical, 4)
                    }
                    Button("Dismiss growth recap") { Task { await sync.dismissRecaps() } }
                        .disabled(sync.busy).accessibilityIdentifier("sync.recapDone")
                    Text("Growth is already saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink("Health activity on this iPhone") { ActivityScreen(store: health) }
            }
        }.navigationTitle("Activity")
            .preference(key: EntryPresentationBlocker.self, value: showingConsent || replacing)
            .refreshable { _ = await sync.synchronize() }
            .alert("Upload activity to your garden?", isPresented: $showingConsent) {
                Button("Enable activity sync") { Task { await sync.setEnabled(true) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Daily quantities and recorded workout details will be saved on this iPhone for reliable retries and sent to Movement Forest to calculate growth. Manually entered workouts do not qualify. Earlier activity earns no growth. Health access is optional.")
            }
            .alert("Replace the reporting iPhone?", isPresented: $replacing) {
                Button("Use this iPhone", role: .destructive) { Task { _ = await sync.synchronize(replacingDevice: true) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Sync the old iPhone first if possible. Activity starts counting afresh on this iPhone; unsubmitted activity from the old device may not earn growth. Previously confirmed growth is preserved.")
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
                Text("New confirmed growth · Review it in Activity").font(.caption).fontWeight(.semibold)
            }
        }
    }
}
