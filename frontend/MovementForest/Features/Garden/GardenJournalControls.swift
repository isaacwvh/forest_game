import SwiftUI

/// Native context menus label an icon on hold without firing its tap action.
struct GardenActionButton: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).frame(minWidth: 44, minHeight: 44)
                .frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.journalTool)
            .accessibilityLabel(title).accessibilityIdentifier(identifier)
            .contextMenu { Button(title) { }.disabled(true) }
    }
}

@MainActor
struct GardenSelectionPopup: View {
    let name: String
    let variant: String
    var rarity: String? = nil
    let stage: String
    let close: () -> Void
    let details: () -> Void
    var plant: GardenPlant? = nil
    var owned: APIOwnedPlant? = nil
    var catalog: (any AssetCatalogProviding)? = nil
    var isSample = false
    var move: (() -> Void)? = nil
    var rotate: (() -> Void)? = nil
    var store: (() -> Void)? = nil
    var editingDisabled = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        JournalPlantFrame(rarity: rarity) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    if !textSize.isAccessibilitySize {
                        Group {
                            if let plant = plant, let catalog = catalog {
                                JournalPlantImage(plant: plant, catalog: catalog)
                            } else { Image(systemName: "leaf").foregroundStyle(JournalTheme.secondary) }
                        }.frame(width: 48, height: 56).padding(4)
                            .background(JournalTheme.sage, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        PlantNameText(name, rarity: rarity, announcesRarity: false)
                            .font(.system(.headline, design: .serif))
                            .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(textSize.isAccessibilitySize ? 1 : 0.75)
                        Text("\(variant) · \(stage)").font(.caption).foregroundStyle(JournalTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let owned = owned {
                            let summary = JournalGrowthSummary(plant: owned)
                            Text(summary.caption).font(.caption2).monospacedDigit()
                                .foregroundStyle(JournalTheme.secondary)
                            if !summary.fullyGrown, let fraction = summary.fraction {
                                ProgressView(value: fraction).tint(JournalTheme.action)
                                    .accessibilityLabel("Progress to next stage")
                            }
                        } else if isSample {
                            Text("Sample plant").font(.caption2).foregroundStyle(JournalTheme.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    JournalRarity(rarity: rarity)
                    Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .buttonStyle(.journalIcon).accessibilityLabel("Close plant selection")
                        .accessibilityIdentifier("garden.selection.close")
                }.padding(.horizontal, 8).padding(.top, 6)
                HStack(spacing: 4) {
                    if let move = move {
                        GardenActionButton(title: "Move", symbol: "arrow.up.and.down.and.arrow.left.and.right",
                            identifier: "editor.move", action: move).disabled(editingDisabled)
                    }
                    if let rotate = rotate {
                        GardenActionButton(title: "Rotate", symbol: "arrow.clockwise",
                            identifier: "editor.rotate", action: rotate).disabled(editingDisabled)
                    }
                    if let store = store {
                        GardenActionButton(title: "Store", symbol: "tray.and.arrow.down",
                            identifier: "editor.store", action: store).disabled(editingDisabled)
                    }
                    GardenActionButton(title: "Plant details", symbol: "info.circle",
                        identifier: "garden.details", action: details)
                }.padding(.horizontal, 4).padding(.bottom, 4)
            }
        }.frame(maxWidth: 520).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain).accessibilityIdentifier("garden.selection")
            .gardenOverlayTarget().padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Sample/read-only snapshots have no earned-water quantity to invent.
@MainActor
struct GardenBrowserTile: View {
    let plant: GardenPlant
    let catalog: any AssetCatalogProviding
    let isSample: Bool
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var nameHeight: CGFloat = 22
    private var rarity: String? { isSample ? SamplePlantPresentation.rarities[plant.speciesId] : nil }
    var body: some View {
        JournalPlantFrame(rarity: rarity) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) {
                    VStack(spacing: 4) {
                        JournalPlantImage(plant: plant, catalog: catalog).frame(height: textSize.isAccessibilitySize ? 112 : 62)
                            .frame(maxWidth: .infinity).padding(4).background(JournalTheme.sage.opacity(0.45))
                        PlantNameText(plant.speciesId.capitalized, rarity: rarity, announcesRarity: false)
                            .font(.system(.subheadline, design: .serif).weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.65).frame(height: nameHeight)
                        Text("\(plant.variantId.capitalized) · \(plant.growthStage.number)/4")
                            .font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                        Text(isSample ? "Sample plant" : "Read-only plant").font(.caption)
                            .foregroundStyle(JournalTheme.secondary).frame(minHeight: 44)
                    }.padding(.bottom, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(plant.speciesId.capitalized), \(plant.variantId.capitalized), \(plant.growthStage.title)")
                    .accessibilityIdentifier("garden.browser.\(plant.id)")
                JournalRarity(rarity: rarity)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
