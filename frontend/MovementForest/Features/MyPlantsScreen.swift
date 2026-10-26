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
                    Image(systemName: "leaf").font(.largeTitle).foregroundStyle(Color.forestTint)
                    Text("Your plants belong here").font(.title2.bold())
                    Text("Sign in through Settings → Account and sign-in to see your planted and stored copies. The sample garden is for exploring.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
            }
        }.navigationTitle("My plants")
    }
}

@MainActor
struct MyPlantsScreen: View {
    @ObservedObject var store: GardenEditorStore
    let catalog: any AssetCatalogProviding
    var body: some View {
        List {
            if store.showingCached {
                Label("Saved plants · Connect to refresh", systemImage: "wifi.slash").font(.callout)
            }
            if store.state.busy { ProgressView("Loading your plants…") }
            if let message = store.message { Text(message).font(.callout) }
            if store.state == .unknown {
                Button("Retry saved edit") { Task { await store.retryPending() } }
            } else if store.state == .authenticationRequired {
                Text("Sign in again through Settings → Account and sign-in. Your saved edits are retained.")
            } else if store.state == .blocked && !store.recoveryLocked {
                Button("Try again") { Task { await store.refresh() } }
            }
            Section("Planted") {
                if let garden = store.confirmed {
                    if garden.plants.isEmpty { Text("No planted copies. Use Edit → Storage to place a plant.").foregroundStyle(.secondary) }
                    ForEach(garden.plants) { plant in
                        NavigationLink {
                            OwnedPlantDetailScreen(store: store, copyID: plant.id, catalog: catalog)
                        } label: { OwnedPlantRow(plant: plant, store: store, catalog: catalog) }
                            .accessibilityIdentifier("myplants.planted.\(plant.id)")
                    }
                } else { Text("Your planted copies will appear when your garden loads.").foregroundStyle(.secondary) }
            }
            Section("Stored") {
                if store.confirmed == nil {
                    Text("Your stored copies will appear when your garden loads.").foregroundStyle(.secondary)
                }
                if store.confirmed != nil && store.inventory.isEmpty && !store.state.busy {
                    Text(store.nextCursor == nil ? "No stored copies in the saved inventory." : "Load more to see your stored copies.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.inventory) { plant in
                    NavigationLink {
                        OwnedPlantDetailScreen(store: store, copyID: plant.id, catalog: catalog)
                    } label: { OwnedPlantRow(plant: plant, store: store, catalog: catalog) }
                        .accessibilityIdentifier("myplants.stored.\(plant.id)")
                }
                InventoryPagination(store: store)
            }
        }.refreshable { await store.refresh() }
    }
}

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
                Text(plant.speciesId.capitalized).font(.headline)
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
                .accessibilityIdentifier("inventory.more")
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
    var body: some View {
        Group {
            if let copy = store.ownedCopy(copyID), let rendered = store.render(copy) {
                PlantDetailScreen(plant: rendered, catalog: catalog, isSample: false, owned: copy, catalogue: store.catalogue)
                    .safeAreaInset(edge: .bottom) {
                        if context == .storagePlacement {
                            Button("Place") {
                                guard store.editing, store.canEdit, let current = store.ownedCopy(copyID), current.placement == nil else { return }
                                store.begin(current, kind: .plant)
                                if store.candidate != nil { placed?() }
                            }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44).padding()
                            .background(Color(uiColor: .systemBackground))
                            .disabled(!store.editing || !store.canEdit || copy.placement != nil)
                            .accessibilityIdentifier("editor.place")
                        }
                    }
            } else {
                Text("This copy is no longer available here. Return to My plants and refresh.")
                    .foregroundStyle(.secondary).padding()
            }
        }
    }
}
