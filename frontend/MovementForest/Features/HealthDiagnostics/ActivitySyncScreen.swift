import SwiftUI

@MainActor
struct ConnectedActivityScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var store: ActivityStore
    let assets: any AssetCatalogProviding
    var body: some View {
        if let sync = connection.activitySync, let editor = connection.editor {
            ActivitySyncScreen(sync: sync, health: store, editor: editor, assets: assets)
        } else {
            ActivityScreen(store: store)
        }
    }
}

@MainActor
struct ActivitySyncScreen: View {
    @ObservedObject var sync: ActivitySyncCoordinator
    @ObservedObject var health: ActivityStore
    @ObservedObject var editor: GardenEditorStore
    private var plants: [APIOwnedPlant] { (editor.confirmed?.plants ?? []) + editor.inventory }
    private var catalogue: APICatalogue? { editor.catalogue }
    let assets: any AssetCatalogProviding
    @State private var showingConsent = false
    @State private var replacing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ActivityTotalsStrip(report: health.report, summary: ActivityRecapSummary(recaps: sync.presentationRecaps),
                                    timeZone: TimeZone(identifier: editor.profile.gameTimezone) ?? .current)
                VStack(alignment: .leading, spacing: 10) {
                    JournalSectionHeading(title: "Sync status")
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
                    Button("Sync now") { Task { _ = await sync.synchronize() } }.frame(minHeight: 44)
                        .buttonStyle(.journalFeatured).controlSize(.large)
                        .disabled(sync.busy || sync.recoveryLocked).accessibilityIdentifier("sync.now")
                    if sync.otherDeviceActive {
                        Button("Use this iPhone for activity") { replacing = true }
                            .buttonStyle(.journalSecondary)
                            .frame(minHeight: 44).disabled(sync.busy || !sync.enabled).accessibilityIdentifier("sync.replace")
                    }
                    if sync.recoveryLocked {
                        Text("Sync is paused to protect a saved update. Sign in again through Settings → Account and sign-in to reconnect. Your saved requests are retained.")
                            .font(.footnote)
                    }

                }
                if !recapRows.isEmpty {
                    RecapPlantGrid(rows: recapRows, catalogue: catalogue, assets: assets)
                    if let date = sync.presentationRecaps.last?.createdAt {
                        Text("Recap confirmed \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(JournalTheme.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    JournalSectionHeading(title: "Activity sync")
                    Toggle("Sync activity with my garden", isOn: Binding(get: { sync.enabled }, set: { value in
                        if value { showingConsent = true }
                        else { Task { await sync.setEnabled(false) } }
                        })).frame(minHeight: 44).disabled(sync.busy || sync.recoveryLocked || !sync.canUpload)
                        .accessibilityIdentifier("sync.enabled")
                    if sync.enabled && !sync.includesOptionalActivity {
                        Text("Steps-only sync").font(.caption).foregroundStyle(.secondary)
                        Button("Enable optional quantities and workouts") { showingConsent = true }.buttonStyle(.journalSecondary).frame(minHeight: 44)
                    }
                    DisclosureGroup("About activity sync") {
                        Text("Supported activity waters planted copies. Stored plants keep their progress without growing. Only new activity after enabling sync earns growth; activity does not award visitor tokens.")
                        Text("Full sync queues daily steps, distance, active energy, flights and recorded workout identity, type, source, timestamps and eligible segments on this iPhone, then uploads them for growth. Pause future uploads with the switch above.")
                    }
                }
                if !sync.recaps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Dismiss recap") { Task { await sync.dismissRecaps() } }
                            .buttonStyle(.journalQuiet)
                            .frame(minHeight: 44).disabled(sync.busy).accessibilityIdentifier("sync.recapDone")
                        Text("Activity and growth are already saved.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Group {
                    NavigationLink("Health activity on this iPhone") { ActivityScreen(store: health) }.frame(minHeight: 44)
                }
            }.padding(16)
        }.background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action).navigationTitle("Activity")
            .task { await sync.refreshDailyActivity() }
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
    private var recapRows: [ActivityRecapRow] {
        let affected = Set(sync.presentationRecaps.flatMap { $0.payload.plants.map(\.plantId) })
        return ActivityRecapRow.make(recaps: sync.presentationRecaps,
                                    plants: plants.filter { $0.placement != nil || affected.contains($0.id) })
    }
}

struct GardenActivityStatus: View {
    @ObservedObject var sync: ActivitySyncCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sync.busy { ProgressView("Syncing activity…") }
            Text(sync.message).font(.caption)
            if !sync.recaps.isEmpty {
                Text("New confirmed activity · Review it in Activity").font(.caption).fontWeight(.semibold)
            }
        }
    }
}
