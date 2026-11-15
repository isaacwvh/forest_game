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
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    if item.placement == nil, let place = place {
                        Button("Place") { place(item) }.buttonStyle(.journalFeatured).frame(minHeight: 44)
                            .disabled(!editingEnabled || store.busy).accessibilityIdentifier("itemDetails.place")
                    }
                    if let quote = quote {
                        if item.placement == nil {
                            Button { confirming = true } label: {
                                QuantityLabel(metric: "tokens", text: "Sell for \(quote.tokens) tokens")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.journalSecondary).disabled(!store.canMutate || !editingEnabled)
                                .accessibilityIdentifier("itemSale.sell")
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                QuantityLabel(metric: "tokens", text: "Sell value: \(quote.tokens) tokens")
                                Text("Store this item before selling it.").font(.callout).foregroundStyle(JournalTheme.secondary)
                            }.accessibilityIdentifier("itemSale.value")
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
            VStack(spacing: 8) {
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
                QuantityLabel(metric: "tokens", text: "\(offer.tokenCost) tokens").font(.callout)
                Button("Purchase", action: purchase).buttonStyle(.journalPrimary)
                    .frame(minHeight: 44).disabled(!store.canBuyItem(offer, quantity: 1))
                    .accessibilityIdentifier("shop.item.\(offer.offerId)")
            }.padding(.bottom, 8).clipShape(RoundedRectangle(cornerRadius: 16))
        }
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
        VStack(spacing: 0) {
            HStack {
                Text("Purchase item?").font(.system(.title2, design: .serif).weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.journalIcon).accessibilityLabel("Cancel purchase").disabled(submitted)
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ItemIcon(appearance: offer.appearance).frame(height: 120).frame(maxWidth: .infinity)
                    PlantNameText(offer.displayName, rarity: offer.rarity).font(.system(.headline, design: .serif))
                    Text(offer.description)
                    QuantityLabel(metric: "tokens", text: "\(offer.tokenCost) per item")
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...max(1, min(20, store.itemCapacity?.room ?? 0)))
                        .disabled(submitted || !store.canMutate).frame(minHeight: 44)
                    QuantityLabel(metric: "tokens", text: "Total: \(total)").font(.headline)
                    if let balance = store.tokenBalance { LabeledContent("Available tokens", value: balance) }
                    if store.itemCapacity?.full == true { Text("Item inventory full. Sell a stored item to make room.") }
                    else if !store.canBuyItem(offer, quantity: quantity) { Text("Not enough tokens or item space.") }
                    if let message = store.message, store.refreshFailed { Text(message).font(.callout) }
                }.padding(20)
            }
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button("Cancel") { dismiss() }.buttonStyle(.journalSecondary).disabled(submitted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button("Purchase") {
                    guard !submitted, store.canBuyItem(offer, quantity: quantity) else { return }
                    submitted = true
                    let count = quantity
                    dismiss()
                    Task { await store.buyItem(offer, quantity: count) }
                }.buttonStyle(.journalFeatured).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(submitted || !store.canBuyItem(offer, quantity: quantity))
                    .accessibilityIdentifier("itemPurchase.confirm")
            }.padding(16).background(JournalTheme.sage.opacity(0.65))
        }.background(JournalTheme.paper).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
