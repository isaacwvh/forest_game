import SwiftUI
import UIKit

struct ItemInspection: Identifiable { let id: UUID }

struct ItemIcon: View {
    let item: APIOwnedItem
    var body: some View {
        Group {
            if let asset = try? BundledItemAssets.resolve(item.rendered()),
               let image = UIImage(contentsOfFile: asset.thumbnailURL.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "shippingbox").resizable().scaledToFit().padding(24)
                    .foregroundStyle(JournalTheme.secondary)
            }
        }.accessibilityHidden(true)
    }
}

@MainActor
struct ItemInventoryPanel: View {
    @ObservedObject var store: GardenEditorStore
    var storageOnly = false
    var onPlace: ((APIOwnedItem) -> Void)? = nil
    @State private var inspection: ItemInspection?
    @State private var placing: APIOwnedItem?
    private var placed: [APIOwnedItem] { store.confirmed?.items ?? [] }
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
                if store.showingCached { Label("Saved items · Connect to refresh", systemImage: "wifi.slash").font(.callout) }
                if let message = store.gardenMessage { Text(message).font(.callout) }
                if !storageOnly {
                    PlantInventoryHeading(title: "In garden", symbol: "tree", count: placed.count)
                    itemGrid(placed)
                }
                PlantInventoryHeading(title: "Stored", symbol: "tray", count: store.itemCapacity?.storedItems)
                itemGrid(store.itemInventory)
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
            .fullScreenCover(item: $inspection, onDismiss: {
                if let item = placing { placing = nil; onPlace?(item) }
            }) { selection in
                ItemDetailScreen(store: store, copyID: selection.id, close: { inspection = nil },
                    place: onPlace.map { _ in { (item: APIOwnedItem) in placing = item; inspection = nil } })
                    .journalModalBackground()
            }
    }

    @ViewBuilder private func itemGrid(_ items: [APIOwnedItem]) -> some View {
        if items.isEmpty { Text("No items here yet.").foregroundStyle(JournalTheme.secondary) }
        JournalGrid {
            ForEach(items) { item in
                Button { inspection = ItemInspection(id: item.id) } label: {
                    VStack(spacing: 8) {
                        ItemIcon(item: item).frame(height: 124).frame(maxWidth: .infinity)
                        PlantNameText(item.displayName, rarity: item.rarity)
                            .font(.system(.headline, design: .serif))
                        Text(item.rarity.capitalized).font(.caption).foregroundStyle(JournalTheme.secondary)
                    }.padding(12).frame(maxWidth: .infinity)
                }.buttonStyle(.journalQuiet)
                    .accessibilityLabel("\(item.displayName), \(item.rarity), \(item.placement == nil ? "stored" : "in garden")")
                    .accessibilityIdentifier("inventory.item.\(item.id)")
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
    private var item: APIOwnedItem? {
        ((store.confirmed?.items ?? []) + store.itemInventory).first { $0.id == copyID }
    }
    var body: some View {
        JournalInspector(title: item?.displayName ?? "Item", close: close,
                         closeLabel: "Close item details", identifier: "itemDetails") {
            if let item = item {
                ItemIcon(item: item).frame(height: 230).frame(maxWidth: .infinity)
                Text(item.rarity.capitalized).font(.subheadline).foregroundStyle(JournalTheme.secondary)
                Text(item.description).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("This copy is no longer available. Refresh your inventory.")
            }
        } footer: {
            if let item = item, item.placement == nil, let place = place {
                Button("Place") { place(item) }.buttonStyle(.journalPrimary)
                    .frame(minHeight: 44).frame(maxWidth: .infinity).padding(16)
                    .disabled(!store.canEdit).accessibilityIdentifier("itemDetails.place")
            }
        }
    }
}

@MainActor
struct ItemPlacementControls: View {
    @ObservedObject var store: GardenEditorStore
    var body: some View {
        if let value = store.itemCandidate {
            VStack(spacing: 10) {
                Text(value.item.displayName).font(.system(.headline, design: .serif))
                if value.action != "rotate" {
                    HStack {
                        Text("X")
                        TextField("X", value: Binding(get: { NSDecimalNumber(decimal: store.itemCandidate?.x ?? 0).doubleValue },
                            set: { store.updatePosition(x: $0, y: NSDecimalNumber(decimal: store.itemCandidate?.y ?? 0).doubleValue) }), format: .number)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel("Item X position")
                        Text("Y")
                        TextField("Y", value: Binding(get: { NSDecimalNumber(decimal: store.itemCandidate?.y ?? 0).doubleValue },
                            set: { store.updatePosition(x: NSDecimalNumber(decimal: store.itemCandidate?.x ?? 0).doubleValue, y: $0) }), format: .number)
                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel("Item Y position")
                    }
                }
                Slider(value: Binding(get: { NSDecimalNumber(decimal: store.itemCandidate?.rotation ?? 0).doubleValue },
                                      set: { store.updateRotation($0) }), in: 0...359.99, step: 0.01)
                    .frame(minHeight: 44).accessibilityLabel("Item rotation")
                HStack {
                    Button("Cancel") { store.cancelCandidate() }.buttonStyle(.journalSecondary)
                    Button("Apply") { Task { await store.releaseCandidate() } }.buttonStyle(.journalPrimary)
                        .disabled(value.validity != .valid || !store.canEdit)
                        .accessibilityIdentifier("editor.item.apply")
                }.frame(minHeight: 44)
            }.padding(12)
        }
    }
}
