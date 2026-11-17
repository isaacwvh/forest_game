import SwiftUI

/// Ephemeral purchase feedback; closing it never acknowledges or clears a receipt.
struct ShopPurchaseNotice: Identifiable, Equatable {
    let id: UUID
    let message: String
    init?(receipt: APICollectionReceipt) {
        let noun: String
        if receipt.purchaseId != nil {
            noun = (receipt.quantity ?? receipt.ownedItemIds?.count ?? 1) == 1 ? "Item" : "Items"
        } else if receipt.exchangeId != nil {
            noun = (receipt.quantity ?? receipt.packs?.count ?? 1) == 1 ? "Pack" : "Packs"
        } else { return nil }
        id = receipt.requestId
        message = "\(noun) saved to Storage."
    }
}

struct ShopPurchasePopup: View {
    let notice: ShopPurchaseNotice
    let close: () -> Void
    @AccessibilityFocusState private var messageFocused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.title3)
                .foregroundStyle(JournalTheme.action).accessibilityHidden(true)
            Text(notice.message).font(.system(.subheadline, design: .serif).weight(.medium))
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityFocused($messageFocused)
            Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .buttonStyle(.journalIcon).accessibilityLabel("Close purchase notification")
                .accessibilityIdentifier("shop.purchaseNotice.close")
        }.padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
            .foregroundStyle(JournalTheme.ink)
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(JournalTheme.vine, lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .frame(maxWidth: 360).accessibilityElement(children: .contain)
            .accessibilityIdentifier("shop.purchaseNotice")
            .onAppear { messageFocused = true }
            .onChange(of: notice.id) { _ in messageFocused = true }
    }
}

struct CatalogCollectionTracker: View {
    let catalogue: APICatalogue?
    @ObservedObject var discovery: CatalogDiscoveryStore
    @Environment(\.dynamicTypeSize) private var textSize
    private var counts: CatalogCollectionCounts? {
        CatalogCollectionCounts(catalogue: catalogue, discovery: discovery.snapshot)
    }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                 count: textSize.isAccessibilitySize ? 1 : 2),
                  alignment: .leading, spacing: 12) {
            metric("Plants collected", collected: counts?.collectedPlants, total: counts?.totalPlants,
                   explanation: "Unique species acquired, including sold plants.", identifier: "plants")
            metric("Variants collected", collected: counts?.collectedVariants, total: counts?.totalVariants,
                   explanation: "Unique non-standard variants acquired, including sold plants.", identifier: "variants")
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(JournalTheme.sage.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("catalog.collection")
    }
    private func metric(_ title: String, collected: Int?, total: Int?, explanation: String, identifier: String) -> some View {
        let value = collected.flatMap { collected in total.map { "\(collected) / \($0)" } } ?? "Unavailable"
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(JournalTheme.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(JournalTheme.ink).accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(value).accessibilityHint(explanation)
            .accessibilityIdentifier("catalog.collection.\(identifier)")
    }
}

/// Collection presentation only; amounts and eligibility remain owned by the coordinator.
struct CollectionJournalFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(JournalTheme.vine.opacity(0.65), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(JournalVines(size: 28).padding(3))
    }
}

struct CollectionWalletSummary: View {
    let balance: String?
    let capacity: APIInventoryCapacity?
    var showsCapacity = true
    var showsPlants = false
    var cached = false
    var gems: String? = nil
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: textSize.isAccessibilitySize ? 1 : 2),
                      alignment: .leading, spacing: 12) { metrics }
            if cached {
                Text("Last confirmed").font(.caption).foregroundStyle(JournalTheme.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(JournalTheme.sage.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("collection.summary")
    }
    @ViewBuilder private var metrics: some View {
        metric("Tokens", value: balance ?? "Unavailable", symbol: "tokens", quantity: true)
        if let gems = gems { metric("Gems", value: gems, symbol: "gems", quantity: true) }
        if showsCapacity, let capacity = capacity {
            metric("Packs", value: "\(capacity.unopenedPacks) / \(capacity.packLimit)", symbol: "shippingbox")
            if showsPlants {
                metric("Plants", value: "\(capacity.ownedPlants) / \(capacity.plantLimit)", symbol: "leaf")
            }
        }
    }
    private func metric(_ title: String, value: String, symbol: String, quantity: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(.caption, design: .serif).weight(.semibold))
                .foregroundStyle(JournalTheme.secondary)
            HStack(spacing: 6) {
                if quantity { QuantityIcon(metric: symbol) }
                else { Image(systemName: symbol).accessibilityHidden(true) }
                Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(JournalTheme.ink).accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(value)")
    }
}

struct CollectionPackArtwork: View {
    let packID: String
    var height: CGFloat = 128
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(JournalTheme.action) }
        }.frame(maxWidth: .infinity).frame(height: height).accessibilityHidden(true)
            .task(id: packID) {
                image = nil
                if let path = PresentationAssets.packPath(packID: packID, part: "sealed") {
                    image = PresentationAssets.image(path, maximumPixels: 420)
                }
            }
    }
}

/// Neutral frame: a pack's possible contents do not give it a plant rarity.
struct CollectionPackCard<Action: View>: View {
    let packID: String
    let name: String
    var price: String? = nil
    var currency: String = "tokens"
    let infoID: String
    var canInspect = true
    let inspect: () -> Void
    @ViewBuilder var action: () -> Action
    @ScaledMetric(relativeTo: .headline) private var nameHeight: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        CollectionJournalFrame {
            VStack(spacing: 8) {
                CollectionPackArtwork(packID: packID, height: textSize.isAccessibilitySize ? 160 : 128)
                    .padding(.vertical, 10).background(JournalTheme.sage.opacity(0.45))
                    .overlay(alignment: .topTrailing) {
                        Button(action: inspect) {
                            Image(systemName: "info.circle").frame(width: 44, height: 44)
                        }.buttonStyle(.journalIcon).disabled(!canInspect)
                            .accessibilityLabel("Contents and odds for \(name)")
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                if canInspect { inspect() }
                            })
                            .accessibilityIdentifier(infoID)
                    }
                Text(name).font(.system(.headline, design: .serif))
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity).frame(height: nameHeight)
                    .multilineTextAlignment(.center).padding(.horizontal, 8)
                if let price = price {
                    QuantityLabel(metric: currency, text: price).font(.subheadline.weight(.medium))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityLabel("\(price) \(currency)").padding(.horizontal, 8)
                }
                action().font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 10).padding(.bottom, 12)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }.foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
    }
}

struct CollectionPlantReceiptCard: View {
    let receipt: APICollectionReceipt
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        if let plant = receipt.plant {
            let summary = JournalGrowthSummary(plant: plant)
            JournalPlantFrame(rarity: receipt.rarity) {
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) :
                    AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                layout {
                    Group {
                        if let catalogue = catalogue {
                            JournalPlantImage(plant: plant.rendered(catalogue: catalogue, assets: assets), catalog: assets)
                        } else { Image(systemName: "leaf").font(.largeTitle) }
                    }.frame(width: 64, height: 64).padding(4)
                        .background(JournalTheme.sage.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        PlantNameText(catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName
                                      ?? plant.speciesId.capitalized,
                                      rarity: receipt.rarity, announcesRarity: false)
                            .font(.system(.subheadline, design: .serif).weight(.semibold))
                        Text("\(catalogue?.variant(species: plant.speciesId, variant: plant.variantId)?.displayName ?? plant.variantId.capitalized) · \(plant.growthStage.title) · \(PackRevealStep.rarityName(receipt.rarity))")
                            .font(.caption).foregroundStyle(JournalTheme.secondary)
                        if let fraction = summary.fraction {
                            ProgressView(value: fraction).tint(JournalTheme.action)
                                .accessibilityLabel("Confirmed opening growth")
                                .accessibilityValue(summary.exactWaterProgress ?? summary.caption)
                        }
                        Text(summary.caption).font(.caption2).foregroundStyle(JournalTheme.secondary)
                    }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(10)
            }.frame(maxWidth: .infinity).foregroundStyle(JournalTheme.ink)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("packs.lastResult")
        }
    }
}

struct CollectionOddsDetails: View {
    let odds: SpeciesDrawOdds
    var catalogue: APICatalogue? = nil
    private var speciesName: String {
        catalogue?.species.first { $0.speciesId == odds.speciesId }?.displayName ?? odds.speciesId.capitalized
    }
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0...4))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(odds.variants) { variant in
                let variantName = catalogue?.variant(species: odds.speciesId, variant: variant.variantId)?.displayName
                    ?? variant.variantId.capitalized
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    PlantNameText("\(speciesName) (\(variantName))", rarity: odds.rarity, announcesRarity: false)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(percent(variant.overall)).monospacedDigit().fixedSize()
                }.font(.callout).accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pack.variant.\(odds.rarity).\(odds.speciesId).\(variant.variantId)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
