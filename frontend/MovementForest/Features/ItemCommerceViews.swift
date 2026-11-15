import SwiftUI

@MainActor
struct ItemSaleControls: View {
    @ObservedObject var store: CollectionCoordinator
    let item: APIOwnedItem
    let editingEnabled: Bool
    var place: ((APIOwnedItem) -> Void)?
    let close: () -> Void
    @State private var quote: APIItemSaleQuote?
    @State private var issue: String?
    @State private var confirming = false
    @State private var loading = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.state.pending != nil {
                Text("Awaiting confirmation").font(.callout)
                Button("Retry saved request") { Task { await store.refresh(); await loadQuote() } }
                    .buttonStyle(.journalSecondary).frame(minHeight: 44).disabled(store.busy)
            } else {
                if let quote = quote {
                    HStack(spacing: 12) {
                        Text("Sell value")
                        Spacer(minLength: 0)
                        QuantityLabel(metric: "tokens", text: "\(quote.tokens) tokens")
                            .monospacedDigit()
                    }.font(.callout).accessibilityElement(children: .combine)
                        .accessibilityIdentifier("itemSale.value")
                }
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    if item.placement == nil, let place = place {
                        Button { place(item) } label: {
                            Text("Place").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.journalFeatured).frame(maxWidth: .infinity)
                            .disabled(!editingEnabled || store.busy).accessibilityIdentifier("itemDetails.place")
                    }
                    if let quote = quote {
                        if item.placement == nil {
                            Button { confirming = true } label: {
                                Text("Sell").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.journalSecondary).frame(maxWidth: .infinity)
                                .disabled(!store.canMutate || !editingEnabled)
                                .accessibilityLabel("Sell for \(quote.tokens) tokens")
                                .accessibilityIdentifier("itemSale.sell")
                        } else {
                            Text("Store this item before selling it.").font(.callout).foregroundStyle(JournalTheme.secondary)
                        }
                    } else if loading { ProgressView("Checking resale value…") }
                }
            }
            if let issue = issue {
                Text(issue).font(.callout)
                Button("Retry resale value") { Task { await loadQuote() } }
                    .buttonStyle(.journalSecondary).frame(minHeight: 44).disabled(loading || store.busy)
            }
            if let message = store.message, store.refreshFailed || store.recoveryLocked { Text(message).font(.callout) }
        }.task(id: item.placement == nil) { await loadQuote() }
            .onReceive(store.$state) { state in
                if state.result?.ownedItemId == item.id && state.result?.saleId != nil { close() }
            }
            .alert("Sell this item?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { }
                if let quote = quote {
                    Button("Sell for \(quote.tokens) tokens", role: .destructive) {
                        Task { await store.sellItem(quote); if store.state.pending == nil { await loadQuote() } }
                    }
                }
            } message: { Text("This action cannot be undone.") }
    }
    private func loadQuote() async {
        guard store.state.pending == nil,
              !(store.state.result?.ownedItemId == item.id && store.state.result?.saleId != nil) else { return }
        loading = true; issue = nil; quote = nil
        defer { loading = false }
        do { quote = try await store.itemSaleQuote(item: item.id) }
        catch { if !Task.isCancelled { issue = PlayerMessage.failure(error, fallback: "Resale value couldn’t load. Connect and retry.") } }
    }
}

@MainActor
struct ItemShopCard: View {
    @ObservedObject var store: CollectionCoordinator
    let offer: APIItemShopOffer
    let purchase: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        JournalPlantFrame(rarity: offer.rarity) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    ItemIcon(appearance: offer.appearance)
                        .frame(height: textSize.isAccessibilitySize ? 112 : 62)
                        .frame(maxWidth: .infinity).padding(4).background(JournalTheme.sage.opacity(0.45))
                    HStack(spacing: 0) {
                        JournalRarity(rarity: offer.rarity)
                        Button(action: purchase) { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.journalIcon).accessibilityLabel("View \(offer.displayName) details")
                    }
                }
                PlantNameText(offer.displayName, rarity: offer.rarity).font(.system(.subheadline, design: .serif).weight(.semibold))
                    .lineLimit(textSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
                QuantityLabel(metric: "tokens", text: offer.tokenCost).font(.callout).monospacedDigit()
                    .accessibilityLabel("\(offer.tokenCost) tokens")
                Button("Purchase", action: purchase).buttonStyle(.journalPrimary)
                    .frame(minHeight: 44).disabled(!store.canBuyItem(offer, quantity: 1))
                    .accessibilityIdentifier("shop.item.\(offer.offerId)")
            }.padding(.bottom, 6).clipShape(RoundedRectangle(cornerRadius: 16))
        }.frame(maxWidth: textSize.isAccessibilitySize ? .infinity : 160, alignment: .leading)
    }
}

@MainActor
struct PurchaseItemScreen: View {
    @ObservedObject var store: CollectionCoordinator
    let offer: APIItemShopOffer
    @State private var quantity = 1
    @State private var submitted = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    private var total: String {
        guard let amount = ExactAmount.integer(offer.tokenCost) else { return "Unavailable" }
        return (amount * Decimal(quantity)).formatted()
    }
    var body: some View {
        JournalInspector(title: "Purchase item?", close: { if !submitted { dismiss() } },
                         closeLabel: "Cancel purchase", identifier: "itemPurchase") {
            ItemIcon(appearance: offer.appearance).frame(height: 120).frame(maxWidth: .infinity)
                .frame(height: 160)
            PlantNameText(offer.displayName, rarity: offer.rarity)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(offer.description).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                QuantityLabel(metric: "tokens", text: "\(offer.tokenCost) per item").monospacedDigit()
                Stepper("Quantity: \(quantity)", value: $quantity, in: 1...max(1, min(20, store.itemCapacity?.room ?? 0)))
                    .disabled(submitted || !store.canMutate).accessibilityIdentifier("itemPurchase.quantity")
                    .frame(minHeight: 44)
                QuantityLabel(metric: "tokens", text: "Total: \(total)").monospacedDigit()
                    .font(.headline).accessibilityLabel("Total: \(total) tokens")
                if let balance = store.tokenBalance { LabeledContent("Available tokens", value: balance).monospacedDigit() }
                if store.itemCapacity?.full == true { Text("Item inventory full. Sell a stored item to make room.") }
                else if !store.canBuyItem(offer, quantity: quantity) { Text("Not enough tokens or item space.") }
                if let message = store.message, store.refreshFailed { Text(message).font(.callout) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button("Cancel") { dismiss() }.buttonStyle(.journalSecondary).disabled(submitted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("itemPurchase.cancel")
                Button {
                    guard !submitted, store.canBuyItem(offer, quantity: quantity) else { return }
                    submitted = true
                    let count = quantity
                    dismiss()
                    Task { await store.buyItem(offer, quantity: count) }
                } label: {
                    Text("Purchase").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.journalFeatured)
                    .disabled(submitted || !store.canBuyItem(offer, quantity: quantity))
                    .accessibilityIdentifier("itemPurchase.confirm")
            }.padding(16).background(JournalTheme.sage.opacity(0.65))
        }
    }
}
