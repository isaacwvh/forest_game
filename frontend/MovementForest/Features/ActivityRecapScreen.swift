import SwiftUI

@MainActor
struct ActivityRecapScreen: View {
    @ObservedObject var recap: AppEntryRecapCoordinator
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your garden update").font(.title2.bold())
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    if recap.loading { ProgressView("Checking activity…") }
                    else { Text(recap.status).accessibilityIdentifier("recap.status") }
                    Text("Activity waters planted copies. Stored plants keep their progress without growing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !recap.rows.isEmpty {
                    Section("Plant progress") {
                        ForEach(recap.rows) { row in
                            HStack(alignment: .top, spacing: 12) {
                                if let plant = row.plant, let catalogue = catalogue {
                                    PlantThumbnail(plant: plant.rendered(catalogue: catalogue, assets: assets), catalog: assets)
                                        .frame(width: 48, height: 64).accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.plant.map { "\($0.speciesId.capitalized) · \($0.variantId.capitalized)" } ?? "Plant \(row.id.uuidString.prefix(8))")
                                        .font(.headline)
                                    if let plant = row.plant,
                                       recap.rows.filter({ $0.plant?.speciesId == plant.speciesId && $0.plant?.variantId == plant.variantId }).count > 1 {
                                        Text("Copy \(row.id.uuidString.prefix(4))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if row.water != "0" {
                                        Text("+\(ExactAmount.water(row.water)) water")
                                        if row.skillWater != "0" {
                                            Text("Includes +\(ExactAmount.water(row.skillWater)) from garden skills")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    } else { Text(row.plant?.growthStage == .adult ? "Fully grown" : "No new confirmed growth").foregroundStyle(.secondary) }
                                    if let before = row.beforeStage, let after = row.afterStage, before != after {
                                        Label("\(before.title) → \(after.title)", systemImage: "leaf")
                                    }
                                    if let plant = row.plant {
                                        PlantGrowthProgress(plant: plant)
                                        if plant.placement == nil { Text("Now in Storage").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }.padding(.vertical, 4).accessibilityElement(children: .combine)
                        }
                    }
                } else if !recap.loading { Text("No plant progress is available yet. Open Garden → Storage to plant a copy.") }
                if !recap.activeSkills.isEmpty {
                    Section("Skills active now") {
                        ForEach(recap.activeSkills) { skill in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name).font(.headline)
                                Text(skill.description).font(.subheadline)
                            }.accessibilityElement(children: .combine)
                        }
                        Text("These are your current skills. Water above includes only bonuses saved with those rewards. A newly adult source affects later uploads.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Welcome back").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Continue") { recap.showing = false }.frame(minHeight: 44)
                    .accessibilityIdentifier("recap.continue")
            } }
            .onAppear { LifecycleDiagnostics.event("entry sheet appeared") }
            .task {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                titleFocused = true
            }
        }
    }
}

struct PlantGrowthProgress: View {
    let plant: APIOwnedPlant
    var body: some View {
        if let progress = plant.growthProgress, let fraction = progress.fraction(growth: plant.growthMicroUnits) {
            if let next = progress.nextStageMicroUnits,
               let target = ExactAmount.integer(next), let current = ExactAmount.integer(plant.growthMicroUnits) {
                ProgressView(value: fraction).accessibilityLabel("Progress to next growth stage")
                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                Text("\(ExactAmount.water(NSDecimalNumber(decimal: max(0, target - current)).stringValue)) water to \(plant.growthStage.next?.title ?? "next stage")")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Fully grown · Still contributes attraction while planted").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
