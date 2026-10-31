import SwiftUI

@MainActor
struct MyPlantsHostScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    var body: some View {
        Group {
            if let editor = connection.editor {
                MyPlantsScreen(store: editor, catalog: catalog).id(editor.id)
            } else if connection.connecting {
                ProgressView("Loading your plants…")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "leaf").font(.largeTitle).foregroundStyle(JournalTheme.action)
                    Text("Your plants belong here").font(.system(.title2, design: .serif).bold())
                    Text("Sign in through Settings → Account and sign-in.")
                        .foregroundStyle(JournalTheme.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(JournalPageBackground().ignoresSafeArea()).navigationTitle("My plants")
    }
}

@MainActor
struct MyPlantsScreen: View {
    @ObservedObject var store: GardenEditorStore
    let catalog: any AssetCatalogProviding
    @State private var inspecting: PlantInspection?
    @State private var search = ""
    @State private var rarity = "All"
    @State private var stage = "All"
    private var filtering: Bool { !search.isEmpty || rarity != "All" || stage != "All" }
    private func matches(_ plant: APIOwnedPlant) -> Bool {
        let name = store.catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName ?? plant.speciesId
        return (search.isEmpty || "\(name) \(plant.variantId)".localizedCaseInsensitiveContains(search))
            && (rarity == "All" || store.catalogue?.rarity(for: plant.speciesId) == rarity)
            && (stage == "All" || plant.growthStage.rawValue == stage)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                JournalSearchField(text: $search)
                status
                JournalSectionHeading(title: "Planted")
                if let garden = store.confirmed {
                    let plants = garden.plants.filter(matches)
                    if plants.isEmpty {
                        Text(filtering ? "No matching planted plants." : "No planted plants.")
                            .foregroundStyle(JournalTheme.secondary)
                    }
                    grid(plants, prefix: "myplants.planted.")
                } else {
                    Text("Your planted copies will appear when your garden loads.").foregroundStyle(JournalTheme.secondary)
                }
                JournalSectionHeading(title: "Stored")
                if store.confirmed == nil {
                    Text("Your stored copies will appear when your garden loads.").foregroundStyle(JournalTheme.secondary)
                } else {
                    let plants = store.inventory.filter(matches)
                    if plants.isEmpty && !store.state.busy {
                        Text(filtering ? "No matching stored plants loaded." :
                            store.nextCursor == nil ? "No stored plants." : "More stored plants are available.")
                            .foregroundStyle(JournalTheme.secondary)
                    }
                    grid(plants, prefix: "myplants.stored.")
                }
                if filtering && store.nextCursor != nil {
                    Text("Filters apply to loaded plants.").font(.caption).foregroundStyle(JournalTheme.secondary)
                }
                InventoryPagination(store: store)
            }.padding(16).padding(.bottom, 16)
        }
        .background(JournalPageBackground().ignoresSafeArea())
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
        .navigationTitle("My plants").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("My plants").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(JournalTheme.ink)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Rarity", selection: $rarity) {
                        Text("All rarities").tag("All")
                        ForEach(PlantRarity.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Growth stage", selection: $stage) {
                        Text("All stages").tag("All")
                        ForEach(GrowthStage.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if filtering { Button("Clear filters") { search = ""; rarity = "All"; stage = "All" } }
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .accessibilityLabel("Filter plants")
            }
        }
        .refreshable { await store.refresh() }
        .fullScreenCover(item: $inspecting) { selection in
            OwnedPlantDetailScreen(store: store, copyID: selection.id, catalog: catalog).journalModalBackground()
        }
        .transformPreference(EntryPresentationBlocker.self) { $0 = $0 || inspecting != nil }
    }

    private func grid(_ plants: [APIOwnedPlant], prefix: String) -> some View {
        JournalGrid {
            ForEach(plants) { plant in
                OwnedPlantTile(plant: plant, store: store, catalog: catalog,
                    identifier: prefix + plant.id.uuidString) { inspecting = PlantInspection(id: plant.id) }
            }
        }
    }
    @ViewBuilder private var status: some View {
        if store.showingCached { Label("Saved plants · Connect to refresh", systemImage: "wifi.slash").font(.callout) }
        if store.state.busy { ProgressView("Loading your plants…") }
        if let message = store.message { Text(message).font(.callout) }
        if store.state == .unknown {
            Button("Retry saved edit") { Task { await store.retryPending() } }
        } else if store.state == .authenticationRequired {
            Text("Sign in again through Settings → Account and sign-in. Your saved edits are retained.").font(.callout)
        } else if store.state == .blocked && !store.recoveryLocked {
            Button("Try again") { Task { await store.refresh() } }
        }
    }
}

@MainActor
struct OwnedPlantTile: View {
    let plant: APIOwnedPlant
    @ObservedObject var store: GardenEditorStore
    let catalog: any AssetCatalogProviding
    let identifier: String
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var nameHeight: CGFloat = 22
    private var rarity: String? { store.catalogue?.rarity(for: plant.speciesId) }
    private var name: String {
        store.catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName ?? plant.speciesId.capitalized
    }
    var body: some View {
        JournalPlantFrame(rarity: rarity) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Button(action: open) {
                        VStack(spacing: 6) {
                            Group {
                                if let rendered = store.render(plant) {
                                    JournalPlantImage(plant: rendered, catalog: catalog)
                                } else { Image(systemName: "leaf").resizable().scaledToFit() }
                            }
                            .frame(height: textSize.isAccessibilitySize ? 112 : 62)
                            .frame(maxWidth: .infinity).padding(4)
                            .background(JournalTheme.sage.opacity(0.45))
                            VStack(spacing: 3) {
                                PlantNameText(name, rarity: rarity, announcesRarity: false)
                                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                                    .lineLimit(1).minimumScaleFactor(0.65).frame(height: nameHeight)
                                Text("\(plant.variantId.capitalized) · \(plant.growthStage.number)/4")
                                    .font(.caption2).foregroundStyle(JournalTheme.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.75)
                            }.padding(.horizontal, 6).multilineTextAlignment(.center)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name), \(plant.variantId.capitalized), \(plant.growthStage.title), \(rarity?.capitalized ?? "Rarity unavailable"), \(JournalGrowthSummary(plant: plant).caption)")
                    .accessibilityIdentifier(identifier)
                    JournalRarity(rarity: rarity)
                }
                JournalPlantProgress(plant: plant).padding(.horizontal, 7).padding(.bottom, 6)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Later-stage browsers retain their existing row layout until their own review batch.
@MainActor
struct OwnedPlantRow: View {
    let plant: APIOwnedPlant
    @ObservedObject var store: GardenEditorStore
    let catalog: any AssetCatalogProviding
    var body: some View {
        HStack(spacing: 12) {
            if let rendered = store.render(plant) {
                PlantThumbnail(plant: rendered, catalog: catalog).frame(width: 48, height: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                PlantNameText(plant.speciesId.capitalized, rarity: store.catalogue?.rarity(for: plant.speciesId)).font(.headline)
                Text("\(plant.variantId.capitalized) · \(plant.growthStage.title)")
                    .font(.subheadline).foregroundStyle(.secondary)
                PlantGrowthProgress(plant: plant)
            }
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

@MainActor
struct InventoryPagination: View {
    @ObservedObject var store: GardenEditorStore
    var body: some View {
        if store.nextCursor != nil {
            Button(store.inventoryLoading ? "Loading…" : "Load more") { Task { await store.loadMore() } }
                .disabled(store.inventoryLoading || !store.canReadInventory)
                .frame(minHeight: 44).accessibilityIdentifier("inventory.more")
        }
    }
}

enum OwnedPlantDetailContext { case readOnly, storagePlacement }

@MainActor
struct OwnedPlantDetailScreen: View {
    @ObservedObject var store: GardenEditorStore
    let copyID: UUID
    let catalog: any AssetCatalogProviding
    var context: OwnedPlantDetailContext = .readOnly
    var placed: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let copy = store.ownedCopy(copyID), let rendered = store.render(copy) {
                PlantDetailScreen(plant: rendered, catalog: catalog, isSample: false, owned: copy,
                    catalogue: store.catalogue, onPlace: placementAction,
                    placementDisabled: !store.editing || !store.canEdit || copy.placement != nil)
            } else {
                JournalInspector(title: "Plant details", close: { dismiss() }) {
                    Text("This copy is no longer available here. Return to My plants and refresh.")
                } footer: { EmptyView() }
            }
        }
    }
    private var placementAction: (() -> Void)? {
        guard context == .storagePlacement else { return nil }
        return { self.place() }
    }
    private func place() {
        guard store.editing, store.canEdit, let current = store.ownedCopy(copyID), current.placement == nil else { return }
        store.begin(current, kind: .plant)
        if store.candidate != nil { placed?() }
    }
}
