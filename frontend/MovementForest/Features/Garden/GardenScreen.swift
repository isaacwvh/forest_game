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
    @State private var plantListPresented = false
    @State private var errorsPresented = false

    var body: some View {
        Group {
            if let garden = store.garden {
                ZStack(alignment: .topLeading) {
                    GardenSceneView(renderer: renderer, garden: garden, catalog: catalog,
                                    motionEnabled: !reduceMotion, active: active && visible && phase == .active)
                        .accessibilityHidden(true)
                    if renderer.isLoading {
                        ProgressView("Growing the view… \(renderer.loadedCount)/\(garden.plants.count)")
                            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(garden.isSample ? "A little forest to explore" : garden.title).font(.headline)
                        Text(garden.isSample ? "Sample garden · Your activity won’t change these plants yet." : "Tap a plant to take a closer look.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 12)
                        .background(Color(uiColor: .systemBackground))
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        if !renderer.errors.isEmpty {
                            Button { errorsPresented = true } label: { Label("Some plants need attention", systemImage: "exclamationmark.triangle") }
                                .font(.subheadline)
                        }
                        HStack {
                            Button { plantListPresented = true } label: { Label("Plants", systemImage: "leaf").frame(minHeight: 44) }
                                .accessibilityIdentifier("garden.plants")
                            Spacer()
                            Button { renderer.zoom(by: 1.2) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44) }
                                .accessibilityLabel("Zoom out")
                            Button { renderer.zoom(by: 0.8) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }
                                .accessibilityLabel("Zoom in")
                            Button { renderer.resetCamera() } label: { Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44) }
                                .accessibilityLabel("Reset garden view")
                        }
                        Text("Drag to orbit · Pinch to zoom · Two fingers to pan")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(.horizontal).padding(.bottom, 8).background(.regularMaterial)
                }
                .sheet(item: $selectedPlant, onDismiss: { renderer.selectedPlantID = nil }) { plant in
                    NavigationStack { PlantDetailScreen(plant: plant, catalog: catalog, isSample: garden.isSample) }
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $plantListPresented) {
                    NavigationStack { GardenPlantList(garden: garden, catalog: catalog) }
                }
                .sheet(isPresented: $errorsPresented) {
                    NavigationStack {
                        List {
                            ForEach(Array(renderer.errors.enumerated()), id: \.offset) { _, error in Text(error) }
                            Button("Reload plants") { errorsPresented = false; renderer.retry(garden, catalog: catalog) }
                        }.navigationTitle("Loading plants")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { errorsPresented = false } } }
                    }
                }
                .onChange(of: renderer.selectedPlantID) { id in selectedPlant = garden.plants.first { $0.id == id } }
            } else if let error = store.error {
                RecoveryView(title: "Your garden couldn’t load", message: error, actionTitle: "Try again") { Task { await store.load() } }
            } else {
                ProgressView("Opening your forest…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Your forest").navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true }
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
                                 plant.growthStage == .adult ? "Fully grown source · Check Active skills for effective bonuses" :
                                 "Requires a fully grown plant in the garden")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(plant.speciesId.capitalized).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
                        Text(plant.speciesId.capitalized).font(.headline)
                        Text("\(plant.variantId.capitalized) · \(plant.growthStage.title)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
        }.navigationTitle("Garden plants")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
