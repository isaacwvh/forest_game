import SwiftUI

@MainActor
struct GardenScreen: View {
    @ObservedObject var store: GardenStore
    let catalog: any AssetCatalogProviding
    var active: Bool
    @StateObject private var renderSession = GardenRenderSession()
    private var renderer: RealityGardenRenderer { renderSession.renderer }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var selectedPlant: GardenPlant?
    @State private var informationPresented = false
    @State private var errorsPresented = false
    private var presenting: Bool { selectedPlant != nil || informationPresented || errorsPresented }

    var body: some View {
        Group {
            if let garden = store.garden {
                GardenViewportLayout(compact: false) {
                    GardenSceneView(renderer: renderer, garden: garden, catalog: catalog,
                        motionEnabled: !reduceMotion, active: active && visible && phase == .active && !presenting)
                } status: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(garden.isSample ? "Sample garden" : garden.title).font(.system(.subheadline, design: .serif))
                            Spacer(minLength: 8)
                            GardenActionButton(title: "Garden info", symbol: "info.circle", identifier: "garden.info") { informationPresented = true }
                                .gardenOverlayTarget()
                        }
                        if renderer.isLoading { ProgressView("Loading plants…").allowsHitTesting(false) }
                        if !renderer.errors.isEmpty {
                            Button { errorsPresented = true } label: {
                                Label("Some plants need attention", systemImage: "exclamationmark.triangle").frame(minHeight: 44)
                            }.gardenOverlayTarget()
                        }
                    }.padding(12).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action).background(JournalTheme.paper)
                } controls: {
                    if let selected = garden.plants.first(where: { $0.id == renderer.selectedPlantID }) {
                        GardenSelectionPopup(name: selected.speciesId.capitalized, variant: selected.variantId.capitalized,
                            rarity: SamplePlantPresentation.rarities[selected.speciesId],
                            stage: selected.growthStage.title, close: { renderer.dismissSelection() },
                            details: { selectedPlant = selected }, plant: selected, catalog: catalog, isSample: garden.isSample)
                    }
                }
                .onPreferenceChange(GardenOverlayFrames.self) { renderer.setOverlayFrames($0) }
                .fullScreenCover(item: $selectedPlant) { plant in
                    PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample)
                        .journalModalBackground()
                }
                .sheet(isPresented: $informationPresented) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                JournalSectionHeading(title: "Active skills")
                                Text("No active skills in this sample garden.").foregroundStyle(JournalTheme.secondary)
                            }.padding(20)
                        }.navigationTitle("Garden information")
                            .background(JournalPageBackground().ignoresSafeArea()).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { informationPresented = false } } }
                    }
                }
                .sheet(isPresented: $errorsPresented) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Some plants couldn’t be displayed. Try loading the artwork again.")
                                Button("Reload plants") { errorsPresented = false; renderer.retry(garden, catalog: catalog) }
                                    .frame(minHeight: 44).buttonStyle(.bordered)
                            }.padding(20)
                        }.navigationTitle("Loading plants")
                            .background(JournalPageBackground().ignoresSafeArea()).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { errorsPresented = false } } }
                    }
                }
            } else if store.error != nil {
                RecoveryView(title: "Your garden couldn’t load", message: "Your garden couldn’t load. Please try again.", actionTitle: "Try again") { Task { await store.load() } }
            } else {
                ProgressView("Opening your forest…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Your forest").navigationBarTitleDisplayMode(.inline)
        .preference(key: EntryPresentationBlocker.self, value: presenting)
        .onAppear { visible = true; LiveGardenDiagnostics.shared.renderer = renderer }
        .onDisappear { visible = false; renderer.setActive(false) }
    }
}

struct PlantDetailScreen: View {
    let plant: GardenPlant
    let catalog: any AssetCatalogProviding
    let isSample: Bool
    var owned: APIOwnedPlant? = nil
    var catalogue: APICatalogue? = nil
    var onPlace: (() -> Void)? = nil
    var placementDisabled = false
    var collection: CollectionCoordinator? = nil
    var saleEnabled = true
    @Environment(\.dismiss) private var dismiss
    private var rarity: String? { isSample ? SamplePlantPresentation.rarities[plant.speciesId] : catalogue?.rarity(for: plant.speciesId) }
    private var name: String {
        catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName ?? plant.speciesId.capitalized
    }
    private var multipliers: [String: Decimal] {
        guard let reference = owned?.pinnedProfiles?.behaviour else { return [:] }
        return catalogue?.profiles?["behaviour"]?.first {
            $0.id == reference.id && $0.version == reference.version
        }?.metricMultipliers ?? [:]
    }
    var body: some View {
        JournalInspector(title: "Plant details", close: { dismiss() }) {
            VStack(spacing: 10) {
                JournalPlantFrame(rarity: rarity) {
                    JournalPlantImage(plant: plant, catalog: catalog, maximumPixels: 600)
                        .frame(width: 148, height: 148).padding(12)
                }.frame(width: 172)
                PlantNameText(name, rarity: rarity)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                Text(plant.variantId.capitalized).font(.subheadline).foregroundStyle(JournalTheme.secondary)
            }
            JournalGrid(minimumWidth: 52, fixedColumns: owned == nil ? 2 : owned?.baseAttractionMicroUnits == nil ? 3 : 4) {
                JournalAttribute(title: "Variant", value: plant.variantId.capitalized,
                    explanation: plant.variantId.capitalized, symbol: "leaf")
                JournalRarity(rarity: rarity).frame(maxWidth: .infinity)
                if let owned = owned {
                    JournalAttribute(title: "Total water", value: JournalAmount.water(owned.growthMicroUnits),
                        explanation: "", metric: "water")
                    if let attraction = owned.baseAttractionMicroUnits {
                        JournalAttribute(title: "Base attraction", value: JournalAmount.water(attraction),
                            explanation: "", metric: "attraction")
                    }
                }
            }.padding(8).background(JournalTheme.sage.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                Text("\(plant.growthStage.title) · \(plant.growthStage.number) / 4")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .accessibilityIdentifier("plantDetails.stage")
                if let owned = owned {
                    JournalPlantProgress(plant: owned)
                    Text(owned.placement == nil ? "In storage" : "Planted")
                        .font(.caption).foregroundStyle(JournalTheme.secondary)
                        .accessibilityIdentifier("plantDetails.placement")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !multipliers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    JournalSectionHeading(title: "Activity multipliers")
                    JournalGrid(minimumWidth: 96) {
                        ForEach(multipliers.keys.sorted(), id: \.self) { key in
                            JournalMetric(title: ActivityMetricLabel.title(key), value: "\(multipliers[key]!.formatted())×",
                                explanation: "", metric: key)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(JournalTheme.sage.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if let owned = owned {
                VStack(alignment: .leading, spacing: 8) {
                    JournalSectionHeading(title: "Garden skills")
                    if let skills = owned.gardenSkills, !skills.isEmpty {
                        ForEach(skills) { skill in
                            DisclosureGroup {
                                Text(skill.description).font(.callout).padding(.top, 6)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(skill.name).font(.headline)
                                    Label(owned.placement == nil ? "Inactive in storage" :
                                        plant.growthStage == .adult ? "Fully grown source" : "Requires a fully grown plant",
                                        systemImage: owned.placement != nil && plant.growthStage == .adult ? "leaf" : "lock")
                                        .font(.caption).foregroundStyle(JournalTheme.secondary)
                                }
                            }.padding(12).background(JournalTheme.sage.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    } else if owned.gardenSkills != nil {
                        Text("No garden skill").font(.callout).foregroundStyle(JournalTheme.secondary)
                    } else {
                        Text("Skill information unavailable").font(.callout).foregroundStyle(JournalTheme.secondary)
                    }
                    if let progress = owned.growthProgress {
                        DisclosureGroup("Growth details") {
                            VStack(alignment: .leading, spacing: 8) {
                                QuantityDetailRow(metric: "water", title: "Stage begins at",
                                    value: JournalAmount.water(progress.stageStartMicroUnits))
                                if let next = progress.nextStageMicroUnits {
                                    QuantityDetailRow(metric: "water", title: "Next stage at", value: JournalAmount.water(next))
                                }
                            }.padding(.top, 8)
                        }.padding(.top, 10)
                    }
                }
            }
            if isSample { Text("Sample plant").font(.caption).foregroundStyle(JournalTheme.secondary) }
            if onPlace == nil, let collection = collection, let owned = owned {
                PlantSaleControls(store: collection, plant: owned, enabled: saleEnabled)
            }
        } footer: {
            if let onPlace = onPlace {
                VStack(spacing: 0) {
                    Divider()
                    if let collection = collection, let owned = owned {
                        PlantSaleControls(store: collection, plant: owned, enabled: saleEnabled,
                            onPlace: onPlace, placementDisabled: placementDisabled).padding(14)
                    } else {
                        Button(action: onPlace) {
                            Text("Place").frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(JournalTheme.paper)
                        }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .padding(14)
                            .disabled(placementDisabled).accessibilityIdentifier("editor.place")
                    }
                }.background(JournalTheme.paper)
            }
        }
    }
}


@MainActor
struct GardenPlantList: View {
    let garden: GardenSnapshot
    let catalog: any AssetCatalogProviding
    @Environment(\.dismiss) private var dismiss
    @State private var inspecting: GardenPlant?
    var body: some View {
        ScrollView {
            JournalGrid {
                ForEach(garden.plants) { plant in
                    GardenBrowserTile(plant: plant, catalog: catalog, isSample: garden.isSample) {
                        inspecting = plant
                    }
                }
            }.padding(16)
        }.navigationTitle("Garden plants").background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $inspecting) { plant in
                PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample).journalModalBackground()
            }
    }
}
