import SwiftUI

enum CollectionDestination: String, CaseIterable, Identifiable {
    case exchange = "Exchange", catalog = "Catalog", draws = "Packs"
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
    var navigate: ((CollectionDestination?) -> Void)? = nil
    var openingChanged: ((Bool) -> Void)? = nil
    var body: some View {
        Group {
            if let store = connection.collection {
                CollectionScreen(store: store, destination: destination, assets: assets, navigate: navigate,
                                 openingChanged: openingChanged).id(store.id)
            } else {
                Text("Connect to your account in Settings to use Exchange, Catalog and Packs.")
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
    var navigate: ((CollectionDestination?) -> Void)? = nil
    var openingChanged: ((Bool) -> Void)? = nil
    @State private var search = ""
    @State private var rarity = "All"
    @State private var confirmingPack: APIOwnedPack?
    @State private var openingPack: APIOwnedPack?
    @State private var inspectingPack: APIPackDefinition?
    @AccessibilityFocusState private var resultFocused: Bool
    private var catalogueSpecies: [APISpecies] { store.catalogue?.species ?? [] }
    private var hasPackModal: Bool { confirmingPack != nil || openingPack != nil || inspectingPack != nil }
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
        .alert("Open pack?", isPresented: Binding(get: { confirmingPack != nil }, set: { if !$0 { confirmingPack = nil } }), presenting: confirmingPack) { pack in
            Button("Cancel", role: .cancel) { confirmingPack = nil }
            Button("Open") { openingPack = pack; confirmingPack = nil }
        } message: { _ in Text("This opens one pack and saves its sprout in Storage.") }
        .fullScreenCover(item: $openingPack, onDismiss: {
            openingChanged?(false)
            resultFocused = store.state.pending == nil && store.state.result?.plant != nil
        }) { pack in
            PackOpeningScreen(store: store, pack: pack, assets: assets)
        }
        .sheet(item: $inspectingPack) { definition in
            NavigationStack {
                PackContentsScreen(pack: definition)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { inspectingPack = nil }
                    } }
            }
        }
        .onChange(of: hasPackModal) { openingChanged?($0) }
        .transformPreference(EntryPresentationBlocker.self) { $0 = $0 || hasPackModal }
        .onDisappear { openingChanged?(false) }
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
                if !store.milestones.isEmpty {
                    Section("Your first garden") {
                        ForEach(store.milestones) { milestone in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(milestone.title).font(.headline)
                                Text(milestone.description).font(.caption).foregroundStyle(.secondary)
                                if milestone.claimed { Label("Claimed", systemImage: "checkmark.circle") }
                                else {
                                    Button("Claim \(milestone.rewardTokens) tokens") {
                                        Task { await store.claim(milestone) }
                                    }.disabled(!milestone.eligible || !store.canMutate)
                                        .accessibilityIdentifier("milestone.\(milestone.id)")
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section("Exchange tokens for packs") {
                    if store.offers.isEmpty && !store.busy { Text("No exchange offers are currently available.") }
                    ForEach(store.offers) { offer in ExchangeOfferRow(store: store, offer: offer, navigate: navigate) }
                }
            case .draws:
                if let result = store.state.result {
                    Section("Latest confirmed result") {
                        ReceiptRow(receipt: result, catalogue: store.catalogue, assets: assets)
                            .accessibilityElement(children: .combine).accessibilityFocused($resultFocused)
                        if result.plant != nil {
                            Button("Go to Garden") { navigate?(nil) }.frame(minHeight: 44)
                        }
                        Button("Dismiss result") { store.dismissResult() }.disabled(store.busy)
                    }
                }
                Section("Unopened packs") {
                    if store.packs.isEmpty && !store.busy { Text("No unopened packs. Exchange visitor tokens for a pack first.") }
                    ForEach(store.packs) { pack in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                PackThumbnail(packID: pack.packId)
                                Text(store.definitions[pack.definitionID]?.displayName ?? pack.packId).font(.headline)
                            }
                            Text("Version \(pack.version) · acquired \(pack.acquiredAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let definition = store.definitions[pack.definitionID] {
                                Button("View contents and odds") { inspectingPack = definition }
                                    .buttonStyle(.bordered).frame(minHeight: 44)
                                    .accessibilityIdentifier("collection.contents.\(pack.id)")
                            }
                            Button("Open pack") { confirmingPack = pack }
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
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
                        ForEach(Array(Set(catalogueSpecies.compactMap(\.rarity))).sorted(), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    ForEach(catalogueSpecies.filter { species in
                        (rarity == "All" || species.rarity == rarity) &&
                        (search.isEmpty || (species.displayName + " " + species.variants.map(\.displayName).joined(separator: " ")).localizedCaseInsensitiveContains(search))
                    }, id: \.speciesId) { species in
                        NavigationLink {
                            CatalogSpeciesScreen(species: species, catalogue: store.catalogue, offers: store.offers, assets: assets)
                        } label: {
                            HStack {
                                if let variant = species.variants.first(where: { $0.variantId == "standard" }) ?? species.variants.first {
                                    CatalogThumbnail(row: CatalogRow(species: species, variant: variant), stage: .sprout, assets: assets)
                                }
                                VStack(alignment: .leading) {
                                    Text(species.displayName)
                                    Text("\(species.rarity?.capitalized ?? "Rarity unavailable") · \(species.variants.count) variants")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.accessibilityIdentifier("catalog.species.\(species.speciesId)")
                    }
                    if catalogueSpecies.isEmpty && !store.busy { Text("Refresh to load the plant catalogue.") }
                }
            }
        }
    }
}

@MainActor
private struct ExchangeOfferRow: View {
    @ObservedObject var store: CollectionCoordinator
    let offer: APIExchangeOffer
    var navigate: ((CollectionDestination?) -> Void)? = nil
    @State private var quantity = 1
    @State private var confirming = false
    private var totalCost: String {
        guard let cost = ExactAmount.integer(offer.tokenCost) else { return "Unavailable" }
        return (cost * Decimal(quantity)).formatted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.pack.displayName).font(.headline)
            Text(offer.pack.description).font(.callout).foregroundStyle(.secondary)
            Text("\(offer.tokenCost) tokens per pack")
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...20).disabled(store.busy || store.state.pending != nil)
            if let cost = ExactAmount.integer(offer.tokenCost) {
                Text("Total: \((cost * Decimal(quantity)).formatted()) tokens").monospacedDigit()
            }
            NavigationLink("View contents and odds") { PackContentsScreen(pack: offer.pack) }
                .frame(minHeight: 44)
                .accessibilityHint("Inspect this pack without spending tokens")
            Button("Exchange \(totalCost) tokens for \(quantity) \(quantity == 1 ? "pack" : "packs")") { confirming = true }
                .disabled(!store.canMutate || !store.canAfford(offer, quantity: quantity))
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                .accessibilityIdentifier("collection.exchange.\(offer.offerId)")
            if store.exchangeOfferID == offer.offerId, let message = store.exchangeMessage {
                Text(message).font(.callout).accessibilityIdentifier("collection.exchangeFeedback")
                if store.state.pending?.kind == .exchange {
                    Button("Retry saved purchase") { Task { await store.refresh() } }
                        .disabled(store.busy).frame(minHeight: 44)
                }
            }
            if let receipt = store.confirmedExchange, receipt.packs?.first?.packId == offer.pack.packId {
                Label("\(receipt.quantity ?? 0) \(offer.pack.displayName) added", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("collection.exchangeSuccess")
                Text("Confirmed purchase · Remaining balance: \(store.tokenBalance ?? receipt.tokenBalance) tokens")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open packs") { navigate?(.draws) }.frame(minHeight: 44)
            }
            if store.tokenBalance != nil && !store.canAfford(offer, quantity: quantity) {
                Text("Earn more visitor tokens to exchange this quantity.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
            .preference(key: EntryPresentationBlocker.self, value: confirming)
            .alert("Exchange tokens?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { }
                Button("Exchange") { Task { await store.exchange(offer, quantity: quantity) } }
            } message: {
                Text("Spend \(totalCost) visitor tokens for \(quantity) \(offer.pack.displayName)?")
            }
    }
}

private struct PackThumbnail: View {
    let packID: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "shippingbox").font(.title) }
        }.frame(width: 48, height: 64).accessibilityHidden(true)
            .task {
                if let path = PresentationAssets.packPath(packID: packID, part: "sealed") {
                    image = PresentationAssets.image(path, maximumPixels: 180)
                }
            }
    }
}

struct PackContentsScreen: View {
    let pack: APIPackDefinition
    var body: some View {
        List {
            Text(pack.description)
            Text(pack.schemaVersion == 2 ? "Choose rarity, then a species equally within that rarity, then its weighted variant." :
                 "Legacy pack: choose rarity, then one listed species/variant outcome equally.")
            ForEach(pack.rarities) { pool in
                Section("\(pool.rarity.capitalized) · \(pack.probability(pool))") {
                    ForEach(pack.speciesOdds.filter { $0.rarity == pool.rarity }) { odds in SpeciesOddsView(odds: odds) }
                }
            }
            Text("Pack version \(pack.version). This pack keeps these contents after future updates.")
                .font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(pack.displayName)
    }
}

struct SpeciesOddsView: View {
    let odds: SpeciesDrawOdds
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0...4))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(odds.speciesId.capitalized).font(.headline)
            Text("Species: \(percent(odds.withinRarity)) within \(odds.rarity.capitalized) · \(percent(odds.overall)) overall")
                .font(.callout)
            ForEach(odds.variants) { variant in
                Text("\(variant.variantId.capitalized): \(percent(variant.conditional)) after this species · \(percent(variant.overall)) overall")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
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

private struct CatalogSpeciesScreen: View {
    let species: APISpecies
    let catalogue: APICatalogue?
    let offers: [APIExchangeOffer]
    let assets: any AssetCatalogProviding
    @State private var variantID = "standard"
    var body: some View {
        if let variant = species.variants.first(where: { $0.variantId == variantID }) ?? species.variants.first {
            CatalogDetailScreen(row: CatalogRow(species: species, variant: variant), catalogue: catalogue,
                                offers: offers, assets: assets, variantID: $variantID)
                .navigationTitle(species.displayName)
        } else { Text("No variants available.") }
    }
}

private struct CatalogDetailScreen: View {
    let row: CatalogRow
    let catalogue: APICatalogue?
    let offers: [APIExchangeOffer]
    let assets: any AssetCatalogProviding
    @Binding var variantID: String
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
                LabeledContent("Rarity", value: row.species.rarity?.capitalized ?? "Unavailable")
                LabeledContent("Clearance radius", value: "\(row.species.clearanceRadius.formatted()) garden units")
                Picker("Variant", selection: $variantID) {
                    ForEach(row.species.variants, id: \.variantId) { Text($0.displayName).tag($0.variantId) }
                }
            }
            Section("Draw probabilities by pack") {
                ForEach(offers.filter { $0.pack.speciesOdds.contains { $0.speciesId == row.species.speciesId } }) { offer in
                    DisclosureGroup("\(offer.pack.displayName) · version \(offer.pack.version)") {
                        ForEach(offer.pack.speciesOdds.filter { $0.speciesId == row.species.speciesId }) { odds in SpeciesOddsView(odds: odds) }
                    }
                }
                Text("Current exchange packs. Older packs keep their own probabilities, shown in Packs.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    LabeledContent(ActivityMetricLabel.title(key), value: "\(multipliers[key]!.formatted())×")
                }
                Text("Recorded workouts use their exact multiplier when listed, otherwise the recorded-workout default. Other unlisted activities contribute no growth.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let skills = profile("behaviour")?.gardenEffects, !skills.isEmpty {
                Section("Garden skills") {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name).font(.headline)
                            Text(skill.description).font(.callout)
                            Text("Requires a fully grown plant in the garden")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
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
        } else if receipt.milestoneId != nil {
            Text("Milestone reward: +\(receipt.tokensEarned ?? "0") visitor tokens.")
        } else {
            Text("Exchanged \(receipt.tokensSpent ?? "0") tokens for \(receipt.quantity ?? 0) packs.")
        }
    }
}
