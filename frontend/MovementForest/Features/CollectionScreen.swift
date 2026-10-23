import SwiftUI

enum CollectionDestination: String, CaseIterable, Identifiable {
    case exchange = "Exchange", catalog = "Catalog", draws = "Draws"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .exchange: return "arrow.left.arrow.right"; case .catalog: return "books.vertical"; case .draws: return "shippingbox" }
    }
}

@MainActor
struct CollectionHostScreen: View {
    @ObservedObject var connection: GardenConnection
    let destination: CollectionDestination
    let assets: any AssetCatalogProviding
    var body: some View {
        Group {
            if let store = connection.collection {
                CollectionScreen(store: store, destination: destination, assets: assets).id(store.id)
            } else {
                Text("Connect to your account in Settings to use Exchange, Catalog and Draws.")
                    .foregroundStyle(.secondary).padding()
            }
        }.navigationTitle(destination.rawValue).navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct CollectionScreen: View {
    @ObservedObject var store: CollectionCoordinator
    let destination: CollectionDestination
    let assets: any AssetCatalogProviding
    @State private var search = ""
    @State private var rarity = "All"
    private var catalogueRows: [CatalogRow] {
        (store.catalogue?.species ?? []).flatMap { species in species.variants.map { CatalogRow(species: species, variant: $0) } }
    }
    var body: some View {
        Group {
            if destination == .catalog { content.searchable(text: $search, prompt: "Find a plant") }
            else { content }
        }
        .refreshable { await store.refresh() }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                .accessibilityLabel("Refresh collection").disabled(store.busy || store.recoveryLocked)
        } }
        .task { await store.refresh() }
    }
    private var content: some View {
        List {
            Section {
                if let balance = store.tokenBalance { Label("\(balance) visitor tokens", systemImage: "sparkles").monospacedDigit() }
                if store.offers.contains(where: { $0.pack.isFixture }) {
                    Text("Development prices and odds · provisional").font(.caption).foregroundStyle(.secondary)
                }
                if store.busy { ProgressView("Confirming with server…") }
                if let message = store.message { Text(message).font(.callout).accessibilityIdentifier("collection.status") }
                if store.state.pending != nil {
                    Text("A saved request is awaiting confirmation. Retry to recover its original result.").font(.callout)
                    Button("Retry saved request") { Task { await store.refresh() } }.disabled(store.busy)
                }
            }
            switch destination {
            case .exchange:
                Section("Exchange tokens for packs") {
                    if store.offers.isEmpty && !store.busy { Text("No exchange offers are currently available.") }
                    ForEach(store.offers) { offer in ExchangeOfferRow(store: store, offer: offer) }
                }
            case .draws:
                if let result = store.state.result {
                    Section("Latest confirmed result") {
                        ReceiptRow(receipt: result, catalogue: store.catalogue, assets: assets)
                        Button("Dismiss result") { store.dismissResult() }.disabled(store.busy)
                    }
                }
                Section("Unopened packs") {
                    if store.packs.isEmpty && !store.busy { Text("No unopened packs. Exchange visitor tokens for a pack first.") }
                    ForEach(store.packs) { pack in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.definitions[pack.definitionID]?.displayName ?? pack.packId).font(.headline)
                            Text("Version \(pack.version) · acquired \(pack.acquiredAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let definition = store.definitions[pack.definitionID] {
                                NavigationLink("Contents and probabilities") { PackContentsScreen(pack: definition) }
                            }
                            Button("Open pack") { Task { await store.open(pack) } }
                                .disabled(!store.canMutate).accessibilityIdentifier("collection.open.\(pack.id)")
                        }.padding(.vertical, 4)
                    }
                    if store.packCursor != nil {
                        Button("Load more packs") { Task { await store.loadMore() } }.disabled(store.busy)
                    }
                }
                Section("Opening history") {
                    ForEach(store.history) { ReceiptRow(receipt: $0, catalogue: store.catalogue, assets: assets) }
                    if store.history.isEmpty { Text("Your confirmed openings appear here.") }
                    if store.historyCursor != nil {
                        Button("Load more results") { Task { await store.loadMore(history: true) } }.disabled(store.busy)
                    }
                }
            case .catalog:
                Section("All plants") {
                    Picker("Rarity", selection: $rarity) {
                        Text("All").tag("All")
                        ForEach(Array(Set(catalogueRows.compactMap { $0.variant.rarity })).sorted(), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    ForEach(catalogueRows.filter { row in
                        (rarity == "All" || row.variant.rarity == rarity) &&
                        (search.isEmpty || "\(row.species.displayName) \(row.variant.displayName)".localizedCaseInsensitiveContains(search))
                    }) { row in
                        NavigationLink {
                            CatalogDetailScreen(row: row, catalogue: store.catalogue, assets: assets)
                        } label: {
                            HStack {
                                CatalogThumbnail(row: row, stage: .sprout, assets: assets)
                                VStack(alignment: .leading) {
                                    Text(row.species.displayName + " · " + row.variant.displayName)
                                    Text(row.variant.rarity?.capitalized ?? "Rarity unavailable").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if catalogueRows.isEmpty && !store.busy { Text("Refresh to load the plant catalogue.") }
                }
            }
        }
    }
}

@MainActor
private struct ExchangeOfferRow: View {
    @ObservedObject var store: CollectionCoordinator
    let offer: APIExchangeOffer
    @State private var quantity = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.pack.displayName).font(.headline)
            Text(offer.pack.description).font(.callout).foregroundStyle(.secondary)
            Text("\(offer.tokenCost) tokens per pack")
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...20).disabled(store.busy || store.state.pending != nil)
            if let cost = ExactAmount.integer(offer.tokenCost) {
                Text("Total: \((cost * Decimal(quantity)).formatted()) tokens").monospacedDigit()
            }
            NavigationLink("Contents and probabilities") { PackContentsScreen(pack: offer.pack) }
            Button("Exchange for \(quantity) \(quantity == 1 ? "pack" : "packs")") { Task { await store.exchange(offer, quantity: quantity) } }
                .disabled(!store.canMutate || !store.canAfford(offer, quantity: quantity))
                .accessibilityIdentifier("collection.exchange.\(offer.offerId)")
            if store.tokenBalance != nil && !store.canAfford(offer, quantity: quantity) {
                Text("Earn more visitor tokens to exchange this quantity.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct PackContentsScreen: View {
    let pack: APIPackDefinition
    var body: some View {
        List {
            Text(pack.description)
            Text("One plant per pack. Rarity is selected first, then one listed plant uniformly within that rarity.")
            ForEach(pack.rarities) { pool in
                Section("\(pool.rarity.capitalized) · \(pack.probability(pool))") {
                    ForEach(pool.outcomes) { outcome in
                        LabeledContent("\(outcome.speciesId.capitalized) · \(outcome.variantId.capitalized)",
                                       value: pack.probability(pool, perPlant: true))
                    }
                }
            }
            Text("Pack version \(pack.version). This pack keeps these contents after future updates.")
                .font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(pack.displayName)
    }
}

struct CatalogRow: Identifiable {
    let species: APISpecies
    let variant: APIVariant
    var id: String { species.speciesId + "/" + variant.variantId }
    func plant(_ stage: GrowthStage) -> GardenPlant {
        GardenPlant(id: UUID(), speciesId: species.speciesId, variantId: variant.variantId,
                    assetVersion: variant.assetCatalogVersion, growthStage: stage, x: 0, y: 0, rotationDegrees: 0)
    }
}

private struct CatalogThumbnail: View {
    let row: CatalogRow
    let stage: GrowthStage
    let assets: any AssetCatalogProviding
    var body: some View { PlantThumbnail(plant: row.plant(stage), catalog: assets).frame(width: 48, height: 56) }
}

private struct CatalogDetailScreen: View {
    let row: CatalogRow
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    private func profile(_ kind: String) -> APICatalogueProfile? {
        let fallback: APIProfileReference?
        switch kind {
        case "growth": fallback = row.species.defaultProfiles?.growth
        case "behaviour": fallback = row.species.defaultProfiles?.behaviour
        default: fallback = row.species.defaultProfiles?.attraction
        }
        let override: APIProfileReference? = row.variant.profileOverrides?[kind] ?? nil
        guard let reference = override ?? fallback else { return nil }
        return catalogue?.profiles?[kind]?.first { $0.id == reference.id && $0.version == reference.version }
    }
    private func amount(_ kind: String, stage: GrowthStage) -> String {
        let values = kind == "growth" ? profile(kind)?.thresholdsMicroUnits : profile(kind)?.stageAttractionMicroUnits
        guard let raw = values?[stage.rawValue] else { return "Unavailable" }
        return ExactAmount.water(raw)
    }
    var body: some View {
        List {
            Section {
                Text(row.species.description ?? "")
                Text(row.variant.description ?? "")
                LabeledContent("Rarity", value: row.variant.rarity?.capitalized ?? "Unavailable")
                LabeledContent("Clearance radius", value: "\(row.species.clearanceRadius.formatted()) garden units")
            }
            Section("Growth and attraction by stage") {
                ForEach(GrowthStage.allCases, id: \.self) { stage in
                    HStack {
                        CatalogThumbnail(row: row, stage: stage, assets: assets)
                        VStack(alignment: .leading) {
                            Text(stage.title).font(.headline)
                            Text("Cumulative growth: \(amount("growth", stage: stage))")
                            Text("Attraction: \(amount("attraction", stage: stage))")
                        }.font(.callout)
                    }
                }
            }
            Section("Activity multipliers") {
                let multipliers = profile("behaviour")?.metricMultipliers ?? [:]
                ForEach(multipliers.keys.sorted(), id: \.self) { key in
                    LabeledContent(key.replacingOccurrences(of: "_", with: " "), value: "\(multipliers[key]!.formatted())×")
                }
                Text("Growth uses the listed activity multipliers. Unlisted activities contribute no growth.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(row.species.displayName + " · " + row.variant.displayName)
    }
}

private struct ReceiptRow: View {
    let receipt: APICollectionReceipt
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    var body: some View {
        if let plant = receipt.plant {
            HStack {
                if let catalogue = catalogue {
                    PlantThumbnail(plant: plant.rendered(catalogue: catalogue, assets: assets), catalog: assets).frame(width: 48, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(plant.speciesId.capitalized) · \(plant.variantId.capitalized)").font(.headline)
                    Text("\(receipt.rarity?.capitalized ?? "Plant") · Awarded as a sprout").font(.caption)
                    if let date = receipt.openedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text("Place new plants from Garden → Storage.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Exchanged \(receipt.tokensSpent ?? "0") tokens for \(receipt.quantity ?? 0) packs.")
        }
    }
}
