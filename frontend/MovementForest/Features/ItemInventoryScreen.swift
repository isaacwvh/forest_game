import SwiftUI
import UIKit

struct ItemInspection: Identifiable { let id: UUID }

struct ItemIcon: View {
    let appearance: GardenItem
    init(item: APIOwnedItem) { appearance = item.rendered() }
    init(appearance: GardenItem) { self.appearance = appearance }
    var body: some View {
        JournalAssetImage(url: (try? BundledItemAssets.resolve(appearance))?.thumbnailURL)
    }
}

@MainActor
struct ItemInventoryPanel: View {
    @ObservedObject var store: GardenEditorStore
    var storageOnly = false
    var onPlace: ((APIOwnedItem) -> Void)? = nil
    var collection: CollectionCoordinator? = nil
    @State private var inspection: ItemInspection?
    @State private var placing: APIOwnedItem?
    private var placed: [APIOwnedItem] { store.editorGarden?.items ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let capacity = store.itemCapacity {
                    Text("Items \(capacity.ownedItems) / \(capacity.itemLimit)")
                        .font(.system(.headline, design: .serif)).monospacedDigit()
                    if capacity.ownedItems >= capacity.itemLimit {
                        Text("Item inventory full.")
                            .font(.callout).foregroundStyle(JournalTheme.secondary)
                    }
                }
                if store.showingCached { Label("Saved items, Connect to refresh", systemImage: "wifi.slash").font(.callout) }
                if let message = store.gardenMessage { Text(message).font(.callout) }
                if !storageOnly {
                    PlantInventoryHeading(title: "In garden", symbol: "tree", count: placed.count)
                    itemGrid(placed)
                }
                PlantInventoryHeading(title: "Stored", symbol: "tray", count: store.editing ? store.storedItems.count : store.itemCapacity?.storedItems)
                itemGrid(store.storedItems)
                if store.itemCursor != nil {
                    Button("Load more items") { Task { await store.loadMoreItems() } }
                        .buttonStyle(.journalSecondary).frame(minHeight: 44)
                        .disabled(!store.canReadInventory || store.inventoryLoading)
                }
                if store.state == .blocked && store.pending == nil && !store.recoveryLocked {
                    Button("Refresh items") { Task { await store.refresh() } }
                        .buttonStyle(.journalSecondary).frame(minHeight: 44)
                }
            }.padding(16)
        }.background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .refreshable { await store.refresh(); await collection?.refresh(scope: .home) }
            .fullScreenCover(item: $inspection, onDismiss: {
                if let item = placing { placing = nil; onPlace?(item) }
            }) { selection in
                ItemDetailScreen(store: store, copyID: selection.id, close: { inspection = nil },
                    place: onPlace.map { _ in { (item: APIOwnedItem) in placing = item; inspection = nil } },
                    collection: collection).journalModalBackground()
            }
            .transformPreference(EntryPresentationBlocker.self) { $0 = $0 || inspection != nil }
    }

    @ViewBuilder private func itemGrid(_ items: [APIOwnedItem]) -> some View {
        if items.isEmpty { Text("No items here yet.").foregroundStyle(JournalTheme.secondary) }
        JournalGrid {
            ForEach(items) { item in
                OwnedItemTile(item: item, identifier: "inventory.item.\(item.id)") {
                    inspection = ItemInspection(id: item.id)
                }
            }
        }
    }
}

@MainActor
struct ItemDetailScreen: View {
    @ObservedObject var store: GardenEditorStore
    let copyID: UUID
    let close: () -> Void
    var place: ((APIOwnedItem) -> Void)? = nil
    var collection: CollectionCoordinator? = nil
    @Environment(\.dynamicTypeSize) private var textSize
    private var item: APIOwnedItem? {
        ((store.editorGarden?.items ?? []) + store.storedItems).first { $0.id == copyID }
    }
    var body: some View {
        JournalInspector(title: item?.displayName ?? "Item", close: close,
                         closeLabel: "Close item details", identifier: "itemDetails",
                         maximumHeight: textSize.isAccessibilitySize ? nil : 490) {
            if let item = item {
                ItemIcon(item: item).frame(height: 150).frame(maxWidth: .infinity)
                Text(item.rarity.capitalized).font(.subheadline).foregroundStyle(JournalTheme.secondary)
                Text(item.flavorDescription).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(item.gardenSkills ?? []) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(.headline)
                        Text(skill.description).font(.callout)
                        Text(item.placement == nil ? "Place this item to enable its skill." : "Placed in your garden.").font(.caption)
                    }
                }
            } else {
                Text("This copy is no longer available. Refresh your inventory.")
            }
        } footer: {
            if let item = item, let collection = collection,
               !store.editing || (item.placement == nil && place != nil && store.canSellFromStorage(copyID)) {
                VStack(spacing: 6) {
                    if store.editing { placementImpact(item) }
                    ItemSaleControls(store: collection, item: item, editingEnabled: store.canEdit,
                                     place: place, close: close)
                }.padding(16).background(JournalTheme.sage.opacity(0.65))
            } else if let item = item, item.placement == nil, let place = place {
                VStack(spacing: 6) {
                    if store.editing { placementImpact(item) }
                    Button { place(item) } label: { Text("Place").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.journalPrimary).disabled(!store.canEdit).accessibilityIdentifier("itemDetails.place")
                }.padding(.horizontal, 12).padding(.vertical, 8).background(JournalTheme.paper)
            }
        }
    }

    private func placementImpact(_ item: APIOwnedItem) -> some View {
        GardenActionImpact(title: store.replacementID == nil ? "If placed" : "If replaced",
            before: store.draftStrategy, after: store.strategyIfPlaced(item))
    }
}

struct OwnedItemTile: View {
    let item: APIOwnedItem
    let identifier: String
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var nameHeight: CGFloat = 22
    var body: some View {
        JournalPlantFrame(rarity: item.rarity) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) {
                    VStack(spacing: 6) {
                        ItemIcon(item: item).frame(height: textSize.isAccessibilitySize ? 112 : 62)
                            .frame(maxWidth: .infinity).padding(4).background(JournalTheme.sage.opacity(0.45))
                        VStack(spacing: 3) {
                            PlantNameText(item.displayName, rarity: item.rarity, announcesRarity: false)
                                .font(.system(.subheadline, design: .serif).weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.65).frame(height: nameHeight)
                            Text(item.rarity.capitalized).font(.caption2).foregroundStyle(JournalTheme.secondary)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }.padding(.horizontal, 6).multilineTextAlignment(.center)
                    }.padding(.bottom, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier(identifier)
                    .accessibilityLabel("\(item.displayName), \(item.rarity), \(item.placement == nil ? "stored" : "in garden")")
                JournalRarity(rarity: item.rarity)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
