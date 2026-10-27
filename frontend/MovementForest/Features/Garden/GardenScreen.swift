import SwiftUI

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
                            Text(garden.isSample ? "Sample garden" : garden.title).font(.subheadline)
                            Spacer(minLength: 8)
                            Button("Garden info") { informationPresented = true }
                                .buttonStyle(GardenOutlineButtonStyle()).accessibilityIdentifier("garden.info")
                                .gardenOverlayTarget()
                        }
                        if renderer.isLoading { ProgressView("Loading plants…").allowsHitTesting(false) }
                        if !renderer.errors.isEmpty {
                            Button { errorsPresented = true } label: {
                                Label("Some plants need attention", systemImage: "exclamationmark.triangle").frame(minHeight: 44)
                            }.gardenOverlayTarget()
                        }
                    }.padding(12)
                } controls: {
                    if let selected = garden.plants.first(where: { $0.id == renderer.selectedPlantID }) {
                        GardenSelectionPopup(name: selected.speciesId.capitalized, variant: selected.variantId.capitalized,
                            rarity: SamplePlantPresentation.rarities[selected.speciesId],
                            stage: selected.growthStage.title, close: { renderer.dismissSelection() },
                            details: { selectedPlant = selected })
                    }
                }
                .onPreferenceChange(GardenOverlayFrames.self) { renderer.setOverlayFrames($0) }
                .sheet(item: $selectedPlant) { plant in
                    NavigationStack { PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample) }
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $informationPresented) {
                    NavigationStack {
                        List {
                            if garden.isSample {
                                Text("Sample garden · Your activity won’t change these plants yet. Sign in to see your own plants.")
                            }
                            Section("Garden controls") { Text("Drag to orbit · Pinch to zoom · Two fingers to pan") }
                            NavigationLink("Explore sample plants") { GardenPlantList(garden: garden, catalog: catalog) }
                                .accessibilityIdentifier("garden.samplePlants")
                        }.navigationTitle("Garden information")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { informationPresented = false } } }
                    }
                }
                .sheet(isPresented: $errorsPresented) {
                    NavigationStack {
                        List {
                            Text("Some plants couldn’t be displayed. Try loading the artwork again.")
                            Button("Reload plants") { errorsPresented = false; renderer.retry(garden, catalog: catalog) }
                        }.navigationTitle("Loading plants")
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
    @Environment(\.dismiss) private var dismiss
    private var rarity: String? { isSample ? SamplePlantPresentation.rarities[plant.speciesId] : catalogue?.rarity(for: plant.speciesId) }
    var body: some View {
        List {
            PlantThumbnail(plant: plant, catalog: catalog).frame(height: 180).frame(maxWidth: .infinity)
            Section {
                DetailRow(title: "Variant", value: plant.variantId.capitalized)
                DetailRow(title: "Growth stage", value: "\(plant.growthStage.number) of 4 · \(plant.growthStage.title)")
                if let owned = owned {
                    QuantityDetailRow(metric: "water", title: "Total water / growth", value: ExactAmount.water(owned.growthMicroUnits))
                    PlantGrowthProgress(plant: owned)
                    if let progress = owned.growthProgress {
                        if let next = progress.nextStageMicroUnits {
                            DetailRow(title: "Next stage at", value: "\(ExactAmount.water(next)) total water")
                        } else { Text("Fully grown").foregroundStyle(.secondary) }
                    }
                    if let attraction = owned.baseAttractionMicroUnits {
                        QuantityDetailRow(metric: "attraction", title: "Base attraction", value: ExactAmount.water(attraction))
                    }
                    Text(owned.placement == nil ? "In storage · Progress is preserved; activity does not grow this copy." :
                         "Planted · Receives newly confirmed eligible activity.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let reference = owned?.pinnedProfiles?.behaviour,
               let multipliers = catalogue?.profiles?["behaviour"]?.first(where: {
                   $0.id == reference.id && $0.version == reference.version
               })?.metricMultipliers {
                Section("Activity multipliers · this copy") {
                    ForEach(multipliers.keys.sorted(), id: \.self) { key in
                        QuantityDetailRow(metric: key, title: ActivityMetricLabel.title(key),
                                          value: "\(multipliers[key]!.formatted())×")
                    }
                    Text("Recorded workouts use their listed multiplier, otherwise the recorded-workout default. Other unlisted activities contribute no growth. Stored copies do not grow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isSample {
                Section { Text("This plant is part of the sample garden. Your own collection and confirmed growth will appear when the garden service is connected.").foregroundStyle(.secondary) }
            }
            if let skills = owned?.gardenSkills, !skills.isEmpty {
                Section("Garden skills") {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name).font(.headline)
                            Text(skill.description).font(.callout)
                            Text(owned?.placement == nil ? "Inactive in storage" :
                                 plant.growthStage == .adult ? "Fully grown source · See Garden info → Active skills for effective bonuses" :
                                 "Requires a fully grown plant in the garden")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(plant.speciesId.capitalized).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { PlantNameText(plant.speciesId.capitalized, rarity: rarity).font(.headline) }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

struct GardenPlantList: View {
    let garden: GardenSnapshot
    let catalog: any AssetCatalogProviding
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(garden.plants) { plant in
            NavigationLink {
                PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample)
            } label: {
                HStack(spacing: 12) {
                    PlantThumbnail(plant: plant, catalog: catalog).frame(width: 48, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        PlantNameText(plant.speciesId.capitalized,
                            rarity: garden.isSample ? SamplePlantPresentation.rarities[plant.speciesId] : nil).font(.headline)
                        Text("\(plant.variantId.capitalized) · \(plant.growthStage.title)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
        }.navigationTitle("Garden plants")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
