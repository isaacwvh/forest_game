import SwiftUI

enum CollectionDestination: String, CaseIterable, Identifiable {
    case exchange = "Exchange", catalog = "Catalog", draws = "Packs", milestones = "Milestones"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .exchange: return "arrow.left.arrow.right"
        case .catalog: return "books.vertical"
        case .draws: return "shippingbox"
        case .milestones: return "checkmark.seal"
        }
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
                Text("Connect to your account in Settings to use Exchange, Catalog, Packs and Milestones.")
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
    @State private var purchasingOffer: APIExchangeOffer?
    @State private var discoveryViewer = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var resultFocused: Bool
    private var catalogueSpecies: [APISpecies] { store.catalogue?.species ?? [] }
    private var hasPackModal: Bool { confirmingPack != nil || openingPack != nil || inspectingPack != nil || purchasingOffer != nil }
    private var latestOpening: APICollectionReceipt? {
        PackResultPresentation.latestOpening(result: store.state.result, history: store.history)
    }
    var body: some View {
        Group {
            if destination == .catalog { catalogContent }
            else { content }
        }
        .refreshable { await refresh() }
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                .accessibilityLabel("Refresh collection").disabled(store.busy || store.recoveryLocked)
        } }
        .task(id: destination) {
            store.discovery.endViewing(discoveryViewer)
            if destination == .catalog { store.discovery.beginViewing(discoveryViewer) }
            await refresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && destination == .catalog { Task { await store.discovery.refresh() } }
        }
        .alert("Open pack?", isPresented: Binding(get: { confirmingPack != nil }, set: { if !$0 { confirmingPack = nil } }), presenting: confirmingPack) { pack in
            Button("Cancel", role: .cancel) { confirmingPack = nil }
            Button("Open") { openingPack = pack; confirmingPack = nil }
        } message: { _ in Text("This opens one pack and saves its sprout in Storage.") }
        .fullScreenCover(item: $openingPack, onDismiss: {
            openingChanged?(false)
            resultFocused = store.state.pending == nil && latestOpening != nil
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
        .sheet(item: $purchasingOffer) { offer in
            PurchasePackScreen(store: store, offer: offer)
        }
        .onChange(of: hasPackModal) { openingChanged?($0) }
        .transformPreference(EntryPresentationBlocker.self) { $0 = $0 || hasPackModal }
        .onDisappear { openingChanged?(false); store.discovery.endViewing(discoveryViewer) }
    }
    private func refresh() async {
        async let collection: Void = store.refresh()
        if destination == .catalog { await store.discovery.refresh() }
        await collection
    }
    private var content: some View {
        List {
            Section {
                if let balance = store.tokenBalance { QuantityLabel(metric: "tokens", text: "\(balance) visitor tokens").monospacedDigit() }
                if store.offers.contains(where: { $0.pack.isFixture }) {
                    Text("Development prices and odds · provisional").font(.caption).foregroundStyle(.secondary)
                }
                if store.busy { ProgressView("Confirming with server…") }
                if let message = store.message, store.refreshFailed || store.recoveryLocked {
                    Text(message).font(.callout).accessibilityIdentifier("collection.status")
                }
                if store.state.pending != nil {
                    Text("Awaiting confirmation").font(.callout)
                    Button("Retry saved request") { Task { await store.refresh() } }.disabled(store.busy)
                }
            }
            switch destination {
            case .milestones:
                Section("Your first garden") {
                    if let confirmedAt = store.milestonesConfirmedAt {
                        Text("\(store.refreshFailed ? "Cached milestones" : "Last confirmed") · \(confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.refreshFailed {
                        Text("Milestones couldn’t refresh. Previously confirmed rewards are retained.")
                        Button("Retry refresh") { Task { await store.refresh() } }.disabled(store.busy)
                    }
                    if store.milestones.isEmpty && !store.busy && !store.refreshFailed && store.milestonesConfirmedAt != nil {
                        Text("No milestones are currently available.")
                    }
                    ForEach(store.milestones) { milestone in
                        milestoneRow(milestone)
                    }
                    if let receipt = store.state.result, receipt.milestoneId != nil {
                        ReceiptRow(receipt: receipt, catalogue: store.catalogue, assets: assets)
                    }
                    if !store.confirmedMilestoneIDs.isEmpty {
                        Button("Spend tokens in Exchange") { navigate?(.exchange) }.frame(minHeight: 44)
                    }
                }
            case .exchange:
                Section("Packs") {
                    if store.offers.isEmpty && !store.busy { Text("No exchange offers are currently available.") }
                    ForEach(store.offers) { offer in
                        ExchangeOfferRow(store: store, offer: offer, navigate: navigate,
                            inspect: { inspectingPack = offer.pack }, purchase: { purchasingOffer = offer })
                    }
                }
            case .draws:
                Section("Unopened packs") {
                    if store.packs.isEmpty && !store.busy {
                        Text("No unopened packs.").foregroundStyle(.secondary)
                        Button("Browse Exchange") { navigate?(.exchange) }.frame(minHeight: 44)
                    }
                    ForEach(store.packs) { pack in
                        CompactPackRow(packID: pack.packId,
                            name: store.definitions[pack.definitionID]?.displayName ?? pack.packId,
                            infoID: "collection.contents.\(pack.id)",
                            canInspect: store.definitions[pack.definitionID] != nil,
                            inspect: { inspectingPack = store.definitions[pack.definitionID] }) {
                            Button("Open pack") { confirmingPack = pack }
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                                .disabled(!store.canMutate).accessibilityIdentifier("collection.open.\(pack.id)")
                        }
                    }
                    if store.packCursor != nil {
                        Button("Load more packs") { Task { await store.loadMore() } }.disabled(store.busy)
                    }
                }
                Section("Last confirmed result") {
                    if let result = latestOpening {
                        ReceiptRow(receipt: result, catalogue: store.catalogue, assets: assets)
                            .accessibilityElement(children: .combine).accessibilityFocused($resultFocused)
                        Button("Go to Garden") { navigate?(nil) }.frame(minHeight: 44)
                    } else {
                        Text("No confirmed opening yet.").foregroundStyle(.secondary)
                    }
                }
            case .catalog: EmptyView()
            }
        }
    }

    private var filteredSpecies: [APISpecies] {
        catalogueSpecies.filter { species in
            (rarity == "All" || species.rarity == rarity) &&
            (search.isEmpty || (species.displayName + " " + species.variants.map(\.displayName).joined(separator: " "))
                .localizedCaseInsensitiveContains(search))
        }
    }
    private var catalogContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                JournalSearchField(text: $search)
                HStack {
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Rarity", selection: $rarity) {
                            Text("All rarities").tag("All")
                            ForEach(Array(Set(catalogueSpecies.compactMap(\.rarity))).sorted(), id: \.self) {
                                Text($0.capitalized).tag($0)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "diamond")
                            Text(rarity == "All" ? "All rarities" : rarity.capitalized)
                            Image(systemName: "chevron.down").font(.caption)
                        }.padding(.horizontal, 14).frame(minHeight: 44)
                            .background(JournalTheme.sage, in: Capsule())
                    }.accessibilityLabel("Filter by rarity")
                }
                CatalogDiscoveryNotice(discovery: store.discovery)
                if store.busy { ProgressView("Refreshing catalog…") }
                if let message = store.message, store.refreshFailed || store.recoveryLocked {
                    Text(message).font(.callout).accessibilityIdentifier("collection.status")
                }
                if store.refreshFailed {
                    Button("Retry refresh") { Task { await refresh() } }.frame(minHeight: 44)
                }
                JournalGrid {
                    ForEach(filteredSpecies, id: \.speciesId) { species in
                        CatalogSpeciesTile(species: species, catalogue: store.catalogue, offers: store.offers,
                                           assets: assets, discovery: store.discovery)
                    }
                }
                if filteredSpecies.isEmpty && !store.busy {
                    Text(catalogueSpecies.isEmpty ? "Refresh to load the plant catalogue." : "No matching plants.")
                        .foregroundStyle(JournalTheme.secondary)
                }
            }.padding(16).padding(.bottom, 20)
        }
        .background(JournalPageBackground().ignoresSafeArea())
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Catalog").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(JournalTheme.ink)
            }
        }
    }


    private func milestoneRow(_ milestone: APIIntroMilestone) -> some View {
        let claimed = milestone.claimed || store.confirmedMilestoneIDs.contains(milestone.id)
        let pending = store.state.pending?.kind == .milestone && store.state.pending?.milestoneID == milestone.id
        return VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                Text(milestone.description).font(.callout).foregroundStyle(.secondary)
            } label: { Text(milestone.title).font(.headline) }
            QuantityLabel(metric: "tokens", text: "Reward: \(milestone.rewardTokens) visitor tokens")
            if pending {
                Label(store.busy ? "Confirming claim…" : "Claim awaiting confirmation", systemImage: "clock")
                if !store.busy {
                    Button("Retry saved claim") { Task { await store.refresh() } }.frame(minHeight: 44)
                }
            } else if claimed {
                Label("Claimed", systemImage: "checkmark.circle")
            } else if milestone.eligible {
                Button("Claim reward") { Task { await store.claim(milestone) } }
                    .disabled(!store.canMutate).frame(minHeight: 44)
                    .accessibilityIdentifier("milestone.\(milestone.id)")
            } else {
                Label("Not yet eligible", systemImage: "lock")
            }
        }.padding(.vertical, 4)
    }
}

@MainActor
private struct ExchangeOfferRow: View {
    @ObservedObject var store: CollectionCoordinator
    let offer: APIExchangeOffer
    var navigate: ((CollectionDestination?) -> Void)? = nil
    let inspect: () -> Void
    let purchase: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompactPackRow(packID: offer.pack.packId, name: offer.pack.displayName,
                price: offer.tokenCost, infoID: "collection.offerContents.\(offer.offerId)", inspect: inspect) {
                Button("Purchase pack", action: purchase)
                    .disabled(!store.canMutate || !store.canAfford(offer, quantity: 1))
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    .accessibilityIdentifier("collection.exchange.\(offer.offerId)")
            }
            if store.exchangeOfferID == offer.offerId, store.confirmedExchange == nil, let message = store.exchangeMessage {
                Text(message).font(.callout).accessibilityIdentifier("collection.exchangeFeedback")
            }
            if let receipt = store.confirmedExchange,
               receipt.packs?.contains(where: { $0.packId == offer.pack.packId && $0.version == offer.pack.version }) == true {
                Label("\(receipt.quantity ?? 0) \(receipt.quantity == 1 ? "pack" : "packs") added", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("collection.exchangeSuccess")
                Button("Open packs") { navigate?(.draws) }.frame(minHeight: 44)
            }
            if store.tokenBalance != nil && !store.canAfford(offer, quantity: 1) {
                Text("Not enough tokens").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Presentation only: receipts and history remain owned by the unchanged coordinator.
enum PackResultPresentation {
    static func latestOpening(result: APICollectionReceipt?, history: [APICollectionReceipt]) -> APICollectionReceipt? {
        (history + [result].compactMap { $0 }).filter { $0.openingId != nil && $0.plant != nil }.max {
            if $0.economyVersion != $1.economyVersion { return $0.economyVersion < $1.economyVersion }
            return ($0.openedAt ?? .distantPast) < ($1.openedAt ?? .distantPast)
        }
    }
}

private struct CompactPackRow<Action: View>: View {
    let packID: String
    let name: String
    var price: String? = nil
    let infoID: String
    var canInspect = true
    let inspect: () -> Void
    @ViewBuilder var action: () -> Action
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PackThumbnail(packID: packID)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                if let price = price { QuantityLabel(metric: "tokens", text: "\(price) tokens").monospacedDigit() }
                if textSize.isAccessibilitySize { action() }
            }.padding(.top, 8)
            VStack(alignment: .trailing, spacing: 0) {
                Button(action: inspect) {
                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                }.buttonStyle(.borderless).disabled(!canInspect)
                    .accessibilityLabel("Contents and odds for \(name)")
                    .accessibilityHint(canInspect ? "View without purchasing or opening" : "Refresh to load contents")
                    .accessibilityIdentifier(infoID)
                if !textSize.isAccessibilitySize { action() }
            }
        }.padding(.vertical, 4)
    }
}

@MainActor
private struct PurchasePackScreen: View {
    @ObservedObject var store: CollectionCoordinator
    let offer: APIExchangeOffer
    @State private var quantity = 1
    @State private var submitted = false
    @Environment(\.dismiss) private var dismiss
    private var totalCost: String {
        guard let cost = ExactAmount.integer(offer.tokenCost) else { return "Unavailable" }
        return (cost * Decimal(quantity)).formatted()
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PackThumbnail(packID: offer.pack.packId)
                        Text(offer.pack.displayName).font(.headline)
                    }
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...20)
                        .disabled(submitted || !store.canMutate).accessibilityIdentifier("purchase.quantity")
                    QuantityLabel(metric: "tokens", text: "Total: \(totalCost) tokens").monospacedDigit()
                    if let balance = store.tokenBalance {
                        LabeledContent("Available tokens", value: balance)
                    }
                    if !store.canAfford(offer, quantity: quantity) {
                        Text("Not enough tokens").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Purchase") {
                        guard !submitted, store.canMutate, store.canAfford(offer, quantity: quantity) else { return }
                        submitted = true
                        let count = quantity
                        dismiss()
                        Task { await store.exchange(offer, quantity: count) }
                    }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(submitted || !store.canMutate || !store.canAfford(offer, quantity: quantity))
                        .accessibilityIdentifier("purchase.confirm")
                }
            }.navigationTitle("Purchase pack?").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(submitted)
                } }
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
            ForEach(pack.rarities) { pool in
                Section {
                    ForEach(pack.speciesOdds.filter { $0.rarity == pool.rarity }) { odds in SpeciesOddsView(odds: odds) }
                } header: {
                    PlantNameText(pool.rarity.capitalized, rarity: pool.rarity, announcesRarity: false,
                        suffix: " · \(pack.probability(pool))").textCase(nil)
                }
            }
        }.navigationTitle(pack.displayName)
    }
}

struct SpeciesOddsView: View {
    let odds: SpeciesDrawOdds
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0...4))) }
    var body: some View {
        DisclosureGroup {
            Text("Species: \(percent(odds.withinRarity)) within \(odds.rarity.capitalized) · \(percent(odds.overall)) overall")
                .font(.callout)
            ForEach(odds.variants) { variant in
                Text("\(variant.variantId.capitalized): \(percent(variant.conditional)) after this species · \(percent(variant.overall)) overall")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            PlantNameText(odds.speciesId.capitalized, rarity: odds.rarity, announcesRarity: false)
        }.padding(.vertical, 4).accessibilityIdentifier("pack.species.\(odds.rarity).\(odds.speciesId)")
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


private struct CatalogDiscoveryNotice: View {
    @ObservedObject var discovery: CatalogDiscoveryStore
    var body: some View {
        if discovery.refreshing {
            ProgressView("Checking discovery…")
        } else if discovery.failed {
            VStack(alignment: .leading, spacing: 6) {
                Text(discovery.snapshot == nil ? "Discovery unavailable" : "Last confirmed discovery")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Retry discovery") { Task { await discovery.refresh() } }.frame(minHeight: 44)
            }
        } else if discovery.snapshot != nil && discovery.lastConfirmed {
            Text("Last confirmed discovery").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CatalogSpeciesTile: View {
    let species: APISpecies
    let catalogue: APICatalogue?
    let offers: [APIExchangeOffer]
    let assets: any AssetCatalogProviding
    @ObservedObject var discovery: CatalogDiscoveryStore
    @ScaledMetric(relativeTo: .headline) private var nameHeight: CGFloat = 24
    var body: some View {
        JournalPlantFrame(rarity: species.rarity) {
            ZStack(alignment: .topTrailing) {
                NavigationLink {
                    CatalogSpeciesScreen(species: species, catalogue: catalogue, offers: offers, assets: assets, discovery: discovery)
                } label: {
                    VStack(spacing: 6) {
                        Group {
                            if let variant = species.variants.first(where: { $0.variantId == "standard" }) ?? species.variants.first {
                                JournalPlantImage(plant: CatalogRow(species: species, variant: variant).plant(.sprout), catalog: assets)
                            } else { Image(systemName: "leaf").resizable().scaledToFit() }
                        }.frame(height: 100).frame(maxWidth: .infinity).padding(8)
                            .background(JournalTheme.sage.opacity(0.45))
                        PlantNameText(species.displayName, rarity: species.rarity, announcesRarity: false)
                            .font(.system(.headline, design: .serif))
                            .lineLimit(1).minimumScaleFactor(0.65).frame(height: nameHeight)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                        HStack(spacing: 4) {
                            Text("\(species.variants.count) \(species.variants.count == 1 ? "variant" : "variants")")
                            Image(systemName: "chevron.right").font(.caption2)
                        }.font(.caption).foregroundStyle(JournalTheme.secondary)
                            .padding(.bottom, 12).padding(.horizontal, 6)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(species.displayName), \(species.rarity?.capitalized ?? "Rarity unavailable"), \(species.variants.count) variants")
                    .accessibilityIdentifier("catalog.species.\(species.speciesId)")
                JournalRarity(rarity: species.rarity)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct CatalogSpeciesScreen: View {
    let species: APISpecies
    let catalogue: APICatalogue?
    let offers: [APIExchangeOffer]
    let assets: any AssetCatalogProviding
    @ObservedObject var discovery: CatalogDiscoveryStore
    @State private var variantID = "standard"
    @State private var discoveryViewer = UUID()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        if let variant = species.variants.first(where: { $0.variantId == variantID }) ?? species.variants.first {
            CatalogDetailScreen(row: CatalogRow(species: species, variant: variant), catalogue: catalogue,
                                offers: offers, assets: assets, discovery: discovery, variantID: $variantID)
                .navigationTitle(species.displayName)
                .task { discovery.beginViewing(discoveryViewer); await discovery.refresh() }
                .onDisappear { discovery.endViewing(discoveryViewer) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await discovery.refresh() } }
                }
                .toolbar { ToolbarItem(placement: .principal) {
                    PlantNameText(species.displayName, rarity: species.rarity).font(.system(.title2, design: .serif).weight(.semibold))
                } }
        } else { Text("No variants available.") }
    }
}

private struct CatalogDetailScreen: View {
    let row: CatalogRow
    let catalogue: APICatalogue?
    let offers: [APIExchangeOffer]
    let assets: any AssetCatalogProviding
    @ObservedObject var discovery: CatalogDiscoveryStore
    @Binding var variantID: String
    @Environment(\.dynamicTypeSize) private var textSize
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
        return JournalAmount.water(raw)
    }
    private var multipliers: [String: Decimal] { profile("behaviour")?.metricMultipliers ?? [:] }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                JournalPlantFrame(rarity: row.species.rarity) {
                    JournalPlantImage(plant: row.plant(.sprout), catalog: assets, maximumPixels: 600)
                        .frame(width: 148, height: 148).padding(12)
                }.frame(width: 172)
                    .accessibilityLabel("\(row.variant.displayName) \(row.species.displayName), sprout, always visible")
                variantPicker
                JournalGrid(minimumWidth: 76, fixedColumns: 3) {
                    JournalAttribute(title: "Variant", value: row.variant.displayName,
                        explanation: row.variant.displayName, symbol: "leaf")
                    JournalRarity(rarity: row.species.rarity).frame(maxWidth: .infinity)
                    JournalAttribute(title: "Clearance radius",
                        value: row.species.clearanceRadius.formatted(.number.precision(.fractionLength(2...3))),
                        explanation: "\(row.species.clearanceRadius.formatted()) garden units",
                        symbol: "scope")
                }.padding(8).background(JournalTheme.sage.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                if let description = CatalogSpeciesCopy.description(for: row.species) {
                    Text(description).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("catalog.description")
                }
                CatalogDiscoveryNotice(discovery: discovery)
                VStack(alignment: .leading, spacing: 8) {
                    JournalSectionHeading(title: "Growth stages")
                    stageGrid
                }
                VStack(alignment: .leading, spacing: 8) {
                    JournalSectionHeading(title: "Activity multipliers")
                    if multipliers.isEmpty {
                        Text("Activity multipliers unavailable").font(.callout).foregroundStyle(JournalTheme.secondary)
                    } else {
                        JournalGrid(minimumWidth: 100) {
                            ForEach(multipliers.keys.sorted(), id: \.self) { key in
                                JournalMetric(title: ActivityMetricLabel.title(key), value: "\(multipliers[key]!.formatted())×",
                                    explanation: "", metric: key)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(JournalTheme.sage.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    JournalSectionHeading(title: "Garden skills")
                    if let skills = profile("behaviour")?.gardenEffects, !skills.isEmpty {
                        ForEach(skills) { skill in
                            DisclosureGroup {
                                Text(skill.description).font(.callout).padding(.top, 6)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(skill.name).font(.headline)
                                    Label("Requires a fully grown plant in the garden", systemImage: "lock")
                                        .font(.caption).foregroundStyle(JournalTheme.secondary)
                                }
                            }.padding(12).background(JournalTheme.sage.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    } else if profile("behaviour") != nil {
                        Text("No garden skill").font(.callout).foregroundStyle(JournalTheme.secondary)
                    } else {
                        Text("Skill information unavailable").font(.callout).foregroundStyle(JournalTheme.secondary)
                    }
                }
                DisclosureGroup("Pack probabilities") {
                    VStack(alignment: .leading, spacing: 12) {
                        let packs = offers.filter { $0.pack.speciesOdds.contains { $0.speciesId == row.species.speciesId } }
                        if packs.isEmpty { Text("Pack probabilities unavailable.").font(.callout) }
                        ForEach(packs) { offer in
                            DisclosureGroup(offer.pack.displayName) {
                                ForEach(offer.pack.speciesOdds.filter { $0.speciesId == row.species.speciesId }) {
                                    SpeciesOddsView(odds: $0)
                                }
                            }
                        }
                    }.padding(.top, 10)
                }.padding(12).background(JournalTheme.sage.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }.padding(18).padding(.bottom, 20)
        }.background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
    }
    private var variantPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(row.species.variants, id: \.variantId) { variant in
                    Button { variantID = variant.variantId } label: {
                        Text(variant.displayName).font(.subheadline.weight(.medium))
                            .fixedSize().padding(.horizontal, 12).frame(minHeight: 44)
                            .foregroundStyle(variantID == variant.variantId ? JournalTheme.paper : JournalTheme.ink)
                            .background(variantID == variant.variantId ? JournalTheme.action : Color.clear, in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(variantID == variant.variantId ? [.isSelected] : [])
                        .accessibilityIdentifier("catalog.variant.\(variant.variantId)")
                }
            }.padding(4).background(JournalTheme.sage, in: Capsule())
            Picker("Variant", selection: $variantID) {
                ForEach(row.species.variants, id: \.variantId) { Text($0.displayName).tag($0.variantId) }
            }.pickerStyle(.menu).frame(minHeight: 44)
        }
    }
    @ViewBuilder private var stageGrid: some View {
        if textSize.isAccessibilitySize {
            VStack(spacing: 10) { ForEach(GrowthStage.allCases) { stageCell($0) } }
        } else if textSize >= .xxLarge {
            twoColumnStages
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(GrowthStage.allCases) { stageCell($0).frame(width: 80) }
                }.fixedSize(horizontal: true, vertical: false)
                twoColumnStages
            }
        }
    }
    private var twoColumnStages: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(GrowthStage.allCases) { stageCell($0) }
        }
    }
    private func stageCell(_ stage: GrowthStage) -> some View {
        let revealed = discovery.revealed(species: row.species.speciesId, variant: row.variant.variantId, stage: stage)
        let status = discovery.status(species: row.species.speciesId, variant: row.variant.variantId, stage: stage)
        return VStack(spacing: 4) {
            Text(stage == .young ? "Young" : stage.title)
                .font(.system(.caption, design: .serif).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            ZStack(alignment: .bottomTrailing) {
                JournalPlantImage(plant: row.plant(stage), catalog: assets, revealed: revealed, maximumPixels: 300)
                    .frame(height: 88).frame(maxWidth: .infinity)
                if !revealed {
                    JournalInfoIcon(title: "\(stage.title), \(status)",
                        explanation: "",
                        symbol: discovery.snapshot == nil ? "questionmark.circle" : "lock.fill")
                }
            }
            JournalMetric(title: "Cumulative water", value: amount("growth", stage: stage),
                explanation: "", metric: "water", compact: true)
            JournalMetric(title: "Base attraction", value: amount("attraction", stage: stage),
                explanation: "", metric: "attraction", compact: true)
            if !revealed {
                Text(status).font(.caption2).foregroundStyle(JournalTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 3)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(JournalTheme.sage.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.variant.displayName) \(row.species.displayName), \(stage.title), \(status)")
        .accessibilityIdentifier("catalog.stage.\(stage.rawValue)")
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
                    PlantNameText(plant.speciesId.capitalized,
                        rarity: receipt.rarity, announcesRarity: false).font(.headline)
                    Text("\(plant.variantId.capitalized) · \(receipt.rarity?.capitalized ?? "Plant")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else if receipt.milestoneId != nil {
            QuantityLabel(metric: "tokens", text: "Milestone reward: +\(receipt.tokensEarned ?? "0") visitor tokens.")
        } else {
            QuantityLabel(metric: "tokens", text: "Exchanged \(receipt.tokensSpent ?? "0") tokens for \(receipt.quantity ?? 0) packs.")
        }
    }
}
