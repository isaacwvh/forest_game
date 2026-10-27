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
                    Text("Garden update").font(.title2.bold())
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    if recap.loading { ProgressView("Checking activity…") }
                    else { Text(recap.status).accessibilityIdentifier("recap.status") }
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
                                    PlantNameText(OwnedCopyLabel.title(row.id, in: recap.rows.compactMap(\.plant)),
                                        rarity: row.plant.flatMap { catalogue?.rarity(for: $0.speciesId) })
                                        .font(.headline)
                                    if row.water != "0" {
                                        Text("+\(ExactAmount.water(row.water)) water")
                                        if row.skillWater != "0" {
                                            DisclosureGroup("Skill bonus: +\(ExactAmount.water(row.skillWater)) water") {
                                                Text("Included in this saved growth reward.").foregroundStyle(.secondary)
                                            }.font(.subheadline)
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
                            }.padding(.vertical, 4)
                        }
                    }
                } else if !recap.loading { Text("No plant progress yet. Plant a copy from Edit → Storage.") }
                if !recap.activeSkills.isEmpty {
                    Section("Skills active now") {
                        ForEach(recap.activeSkills) { skill in
                            DisclosureGroup {
                                Text(skill.description).font(.subheadline)
                            } label: { SkillSummaryLabel(skill: skill) }
                        }
                        DisclosureGroup("About these bonuses") {
                            Text("These are current skills. Growth above includes only bonuses saved with those rewards; newly adult sources affect later uploads.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
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
            } else { Text("Fully grown").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
