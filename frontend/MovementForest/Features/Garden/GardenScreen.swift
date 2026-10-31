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
                .fullScreenCover(item: $selectedPlant) { plant in
                    PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample)
                        .journalModalBackground()
                }
                .sheet(isPresented: $informationPresented) {
                    NavigationStack {
                        List {
                            Section("Active skills") {
                                Text("No active skills in this sample garden.").foregroundStyle(.secondary)
                            }
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
    var onPlace: (() -> Void)? = nil
    var placementDisabled = false
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
                    explanation: "\(plant.variantId.capitalized) variant of \(name).", symbol: "leaf")
                JournalRarity(rarity: rarity).frame(maxWidth: .infinity)
                if let owned = owned {
                    JournalAttribute(title: "Total water", value: ExactAmount.water(owned.growthMicroUnits),
                        explanation: "Total confirmed water earned by this copy.", metric: "water")
                    if let attraction = owned.baseAttractionMicroUnits {
                        JournalAttribute(title: "Base attraction", value: ExactAmount.water(attraction),
                            explanation: owned.placement == nil
                                ? "Base attraction at this stage. This stored copy currently contributes no garden attraction."
                                : "Base attraction of this copy at its confirmed stage.", metric: "attraction")
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
                                explanation: multiplierExplanation(key), metric: key)
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
                                    value: ExactAmount.water(progress.stageStartMicroUnits))
                                if let next = progress.nextStageMicroUnits {
                                    QuantityDetailRow(metric: "water", title: "Next stage at", value: ExactAmount.water(next))
                                }
                            }.padding(.top, 8)
                        }.padding(.top, 10)
                    }
                }
            }
            if isSample { Text("Sample plant").font(.caption).foregroundStyle(JournalTheme.secondary) }
        } footer: {
            if let onPlace = onPlace {
                VStack(spacing: 0) {
                    Divider()
                    Button(action: onPlace) {
                        Text("Place").frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(JournalTheme.paper)
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .padding(14)
                        .disabled(placementDisabled).accessibilityIdentifier("editor.place")
                }.background(JournalTheme.paper)
            }
        }
    }
    private func multiplierExplanation(_ key: String) -> String {
        let prefix = "\(ActivityMetricLabel.title(key)): \(multipliers[key]?.formatted() ?? "Unavailable")× for this copy."
        return key == "workout_minutes.*" ? prefix + " The recorded-workout default applies when no exact workout multiplier is listed."
            : prefix
    }
}


struct GardenPlantList: View {
    let garden: GardenSnapshot
    let catalog: any AssetCatalogProviding
    @Environment(\.dismiss) private var dismiss
    @State private var inspecting: GardenPlant?
    var body: some View {
        List(garden.plants) { plant in
            Button { inspecting = plant } label: {
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
            .fullScreenCover(item: $inspecting) { plant in
                PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample).journalModalBackground()
            }
    }
}
