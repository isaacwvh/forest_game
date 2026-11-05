import SwiftUI

struct PlantInventoryHeading: View {
    let title: String
    let symbol: String
    let count: Int?
    var limit: Int? = nil
    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(.title3, design: .serif).weight(.semibold))
            Rectangle().fill(JournalTheme.vine.opacity(0.45)).frame(height: 1).accessibilityHidden(true)
            if let count = count {
                Text(limit.map { "\(count) / \($0)" } ?? "\(count)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(JournalTheme.sage, in: Capsule())
            }
        }.foregroundStyle(JournalTheme.ink).padding(.top, 8).padding(.bottom, 4)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

struct PlantCapacitySummary: View {
    let capacity: APIInventoryCapacity
    var cached = false
    var compact = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { counts }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: compact ? 12 : 20) { counts }
            }
            if cached { Text("Last confirmed capacity").font(.caption).foregroundStyle(JournalTheme.secondary) }
            if capacity.plantFull && !compact {
                Text("Collection full. Sell a stored plant to open another pack.")
                    .font(.callout).foregroundStyle(JournalTheme.ink)
            }
        }.padding(compact ? 10 : 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(JournalTheme.sage.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier(compact ? "editor.capacity" : "myplants.capacity")
    }
    @ViewBuilder private var counts: some View {
        count("Plants", value: "\(capacity.ownedPlants) / \(capacity.plantLimit)")
        count("Planted", value: "\(capacity.plantedPlants) / \(capacity.plantedLimit)")
        count("Stored", value: "\(capacity.storedPlants)")
    }
    private func count(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(compact ? .caption : .subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(JournalTheme.secondary)
            Text(value).font((compact ? Font.callout : Font.body).weight(.medium)).monospacedDigit().foregroundStyle(JournalTheme.ink)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

@MainActor
struct PlantSaleControls: View {
    @ObservedObject var store: CollectionCoordinator
    let plant: APIOwnedPlant
    var enabled = true
    var onPlace: (() -> Void)? = nil
    var placementDisabled = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var quote: APIPlantSaleQuote?
    @State private var loading = false
    @State private var issue: String?
    @State private var retryable = true
    @State private var confirming = false
    @State private var submitting = false
    private var sold: Bool { store.state.result?.saleId != nil && store.state.result?.plantId == plant.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if onPlace == nil { JournalSectionHeading(title: "Sell plant") }
            if sold {
                Label("Sold for \(store.state.result?.tokensEarned ?? "0") tokens", systemImage: "checkmark.circle")
            } else if let pending = store.state.pending {
                Text("A collection request is awaiting confirmation.").font(.callout)
                Button("Retry saved request") { Task { await store.refresh(); await loadQuote() } }
                    .buttonStyle(.journalSecondary)
                    .frame(minHeight: 44).disabled(store.busy)
                    .accessibilityIdentifier("plantSale.retry.\(pending.id)")
            } else if loading {
                ProgressView("Checking resale value…")
            } else if let quote = quote {
                if plant.placement != nil {
                    Text("Store this plant before selling it.").font(.callout).foregroundStyle(JournalTheme.secondary)
                    QuantityLabel(metric: "tokens", text: "Sell value: \(quote.tokens) tokens")
                        .accessibilityIdentifier("plantSale.value")
                } else {
                    let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        placeButton
                        Button { confirming = true } label: {
                            QuantityLabel(metric: "tokens", text: "Sell for \(quote.tokens) tokens")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.journalSecondary).tint(JournalTheme.action)
                            .disabled(!enabled || !store.canMutate || submitting)
                            .accessibilityIdentifier("plantSale.sell")
                    }
                }
            }
            if quote == nil && !sold { placeButton }
            if let issue = issue {
                Text(issue).font(.callout).foregroundStyle(JournalTheme.secondary)
                if retryable {
                    Button("Retry resale value") { Task { await loadQuote() } }
                        .buttonStyle(.journalSecondary)
                        .frame(minHeight: 44).disabled(loading || store.busy)
                }
            }
            if let message = store.message, store.refreshFailed || store.recoveryLocked {
                Text(message).font(.callout).foregroundStyle(JournalTheme.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: plant.growthMicroUnits + (plant.placement == nil ? "/stored" : "/planted")) { await loadQuote() }
            .onReceive(store.$state) { state in
                if state.result?.saleId != nil && state.result?.plantId == plant.id { dismiss() }
            }
            .alert("Sell this plant?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { }
                if let quote = quote {
                    Button("Sell for \(quote.tokens) tokens", role: .destructive) {
                        submitting = true
                        Task {
                            await store.sell(quote)
                            submitting = false
                            if !sold && store.state.pending == nil { await loadQuote() }
                        }
                    }
                }
            } message: {
                Text("This action cannot be undone.")
            }
    }
    @ViewBuilder private var placeButton: some View {
        if let onPlace = onPlace {
            Button(action: onPlace) {
                Text("Place").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.journalFeatured).controlSize(.large)
                .disabled(placementDisabled || store.busy || store.state.pending != nil)
                .accessibilityIdentifier("editor.place")
        }
    }
    private func loadQuote() async {
        guard !sold else { return }
        loading = true; issue = nil; quote = nil; retryable = true
        defer { loading = false }
        do {
            let result = try await store.saleQuote(plant: plant.id)
            guard !Task.isCancelled else { return }
            quote = result
        } catch {
            guard !Task.isCancelled else { return }
            retryable = !["starter_protected", "sale_unavailable", "plant_not_found", "plant_is_planted"]
                .contains((error as? APIError)?.code ?? "")
            issue = PlayerMessage.failure(error, fallback: "Resale value couldn’t load. Connect and try again.")
        }
    }
}

@MainActor
struct MyPlantsHostScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    var body: some View {
        Group {
            if let editor = connection.editor {
                MyPlantsScreen(store: editor, catalog: catalog, collection: connection.collection).id(editor.id)
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
            .task(id: connection.collection?.id) { await connection.collection?.refresh() }
    }
}

@MainActor
struct MyPlantsScreen: View {
    @ObservedObject var store: GardenEditorStore
    let catalog: any AssetCatalogProviding
    var collection: CollectionCoordinator? = nil
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
                if let capacity = store.capacity {
                    PlantCapacitySummary(capacity: capacity, cached: store.showingCached)
                }
                PlantInventoryHeading(title: "Planted", symbol: "leaf", count: store.confirmed?.plants.count,
                    limit: store.capacity?.plantedLimit)
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
                PlantInventoryHeading(title: "Stored", symbol: "tray", count: store.capacity?.storedPlants)
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
                    .buttonStyle(.journalIcon)
                    .accessibilityLabel("Filter plants")
            }
        }
        .refreshable { await store.refresh(); await collection?.refresh() }
        .fullScreenCover(item: $inspecting) { selection in
            OwnedPlantDetailScreen(store: store, copyID: selection.id, catalog: catalog,
                collection: collection).journalModalBackground()
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
                .buttonStyle(.journalSecondary)
        } else if store.state == .authenticationRequired {
            Text("Sign in again through Settings → Account and sign-in. Your saved edits are retained.").font(.callout)
        } else if store.state == .blocked && !store.recoveryLocked {
            Button("Try again") { Task { await store.refresh() } }
                .buttonStyle(.journalSecondary)
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
                .buttonStyle(.journalSecondary)
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
    var collection: CollectionCoordinator? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let copy = store.ownedCopy(copyID), let rendered = store.render(copy) {
                PlantDetailScreen(plant: rendered, catalog: catalog, isSample: false, owned: copy,
                    catalogue: store.catalogue, onPlace: placementAction,
                    placementDisabled: !store.editing || !store.canEdit || copy.placement != nil,
                    collection: collection, saleEnabled: store.canReadInventory && !store.showingCached &&
                        !store.connectionBusy && (!store.editing || store.canEdit) && store.candidate == nil)
            } else if collection?.state.result?.saleId != nil && collection?.state.result?.plantId == copyID {
                Color.clear.onAppear { dismiss() }
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
