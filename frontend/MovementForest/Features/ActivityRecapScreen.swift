import SwiftUI

@MainActor
struct ActivityRecapScreen: View {
    @ObservedObject var recap: AppEntryRecapCoordinator
    @ObservedObject var health: ActivityStore
    let gameTimezone: String
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Activity recap").font(.system(.title2, design: .serif).weight(.semibold))
                .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ActivityTotalsStrip(report: health.report, summary: recap.loading ? nil : recap.activitySummary,
                                        timeZone: TimeZone(identifier: gameTimezone) ?? .current)
                    if recap.loading { ProgressView("Checking activity…") }
                    else { Text(recap.status).font(.callout).accessibilityIdentifier("recap.status") }
                    if !recap.rows.isEmpty {
                        RecapPlantGrid(rows: recap.rows, catalogue: catalogue, assets: assets)
                    } else if !recap.loading { Text("No planted copies to show.").font(.callout) }
                    if !recap.activeSkills.isEmpty {
                        DisclosureGroup("Skills active now") {
                            ForEach(recap.activeSkills) { skill in
                                DisclosureGroup {
                                    Text(skill.description).font(.subheadline)
                                } label: { SkillSummaryLabel(skill: skill) }
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            Divider()
            Button("Continue") { recap.showing = false }
                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("recap.continue").padding(16)
        }.background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .onAppear { LifecycleDiagnostics.event("entry sheet appeared") }
            .task {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                titleFocused = true
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
