import SwiftUI

enum ActivityJournalTheme {
    static let added = Color(red: 0.82, green: 0.38, blue: 0.07)
    static let addedText = Color(red: 0.65, green: 0.27, blue: 0.04)
}

@MainActor
struct ActivityTotalsStrip: View {
    let report: ActivityReport?
    let summary: ActivityRecapSummary?
    let timeZone: TimeZone
    var showsNewActivity = true
    @ScaledMetric(relativeTo: .body) private var itemWidth: CGFloat = 136
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = ActivityDailyTotals(report: report, timeZone: timeZone, now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                JournalSectionHeading(title: "Today")
                Text("\(ActivityCalendar.dayLabel(context.date, timeZoneIdentifier: timeZone.identifier)) · \(timeZone.identifier)")
                    .font(.caption).foregroundStyle(JournalTheme.secondary)
                if showsNewActivity {
                    Text("New in this recap").font(.caption.weight(.semibold)).foregroundStyle(ActivityJournalTheme.addedText)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ActivityDisplayMetric.allCases) { metric in
                            VStack(spacing: 4) {
                                JournalInfoIcon(title: metric.title, explanation: "", metric: metric.key)
                                Text(label(today.amounts[metric], metric: metric))
                                    .font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                                    .accessibilityLabel("\(metric.title), today, \(label(today.amounts[metric], metric: metric))")
                                if showsNewActivity {
                                    Text(newLabel(metric)).font(.caption.weight(.semibold)).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                        .foregroundStyle((summary?.amounts[metric] ?? 0) > 0
                                            ? ActivityJournalTheme.addedText : JournalTheme.secondary)
                                        .accessibilityLabel("\(metric.title), \(newLabel(metric)), in this recap")
                                }
                            }.padding(10).frame(width: itemWidth)
                                .background(JournalTheme.sage, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("activity.total.\(metric.id)")
                        }
                    }.padding(.bottom, 6)
                }.accessibilityIdentifier("activity.totals.scroll")
                if let report = report {
                    Text("Health checked \(report.observedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(JournalTheme.secondary)
                }
            }.foregroundStyle(JournalTheme.ink).accessibilityIdentifier("activity.totals")
        }
    }
    private func label(_ value: Decimal?, metric: ActivityDisplayMetric) -> String {
        guard let value = value else { return "Unavailable" }
        return "\(ActivityDisplayAmount.text(value, decimals: metric.decimals)) \(metric.unit)"
    }
    private func newLabel(_ metric: ActivityDisplayMetric) -> String {
        guard let summary = summary else { return "Checking…" }
        guard let value = summary.amounts[metric] else { return "New unavailable" }
        let text = ActivityDisplayAmount.text(value, decimals: metric.decimals)
        return "\(value == 0 || text.hasPrefix("<") ? "" : "+")\(text) new"
    }
}

@MainActor
struct RecapPlantGrid: View {
    let rows: [ActivityRecapRow]
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalSectionHeading(title: "Plant progress")
            Text("Progress to fully grown").font(.caption).foregroundStyle(JournalTheme.secondary)
            HStack(spacing: 14) {
                Label("Existing", systemImage: "square.fill").foregroundStyle(JournalTheme.action)
                Label("New water", systemImage: "square.fill").foregroundStyle(ActivityJournalTheme.addedText)
            }.font(.caption)
            JournalGrid {
                ForEach(rows) { row in RecapPlantTile(row: row, catalogue: catalogue, assets: assets) }
            }
        }
    }
}

@MainActor
private struct RecapPlantTile: View {
    let row: ActivityRecapRow
    let catalogue: APICatalogue?
    let assets: any AssetCatalogProviding
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var nameHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var footerHeight: CGFloat = 44
    private var rarity: String? { row.speciesID.flatMap { catalogue?.rarity(for: $0) } }
    private var stage: GrowthStage? { row.afterStage ?? row.plant?.growthStage }
    private var name: String {
        row.speciesID.map { id in catalogue?.species.first { $0.speciesId == id }?.displayName ?? id.capitalized }
            ?? "Plant \(row.id.uuidString.prefix(6))"
    }
    private var portrait: GardenPlant? {
        guard let species = row.speciesID, let variant = row.variantID, let stage = stage else { return nil }
        let version = catalogue?.variant(species: species, variant: variant)?.assetCatalogVersion
            ?? assets.species.first { $0.speciesId == species }?.assetVersion ?? "unavailable"
        return GardenPlant(id: row.id, speciesId: species, variantId: variant, assetVersion: version,
                           growthStage: stage, x: 0, y: 0, rotationDegrees: 0)
    }
    private var gain: String {
        if (ExactAmount.integer(row.water) ?? 0) > 0 {
            let text = JournalAmount.water(row.water)
            return "\(text.hasPrefix("<") ? "" : "+")\(text) water"
        }
        return stage == .adult ? "Fully grown" : "No new water"
    }
    private var stageLabel: String {
        if let before = row.beforeStage, let after = row.afterStage, before != after {
            return "\(before == .young ? "Young" : before.title) → \(after == .young ? "Young" : after.title)"
        }
        return stage.map { $0 == .young ? "Young" : $0.title } ?? "Stage unavailable"
    }
    var body: some View {
        JournalPlantFrame(rarity: rarity) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let portrait = portrait { JournalPlantImage(plant: portrait, catalog: assets) }
                        else { Image(systemName: "leaf").foregroundStyle(JournalTheme.secondary) }
                    }.frame(height: textSize.isAccessibilitySize ? 112 : 62)
                        .frame(maxWidth: .infinity).padding(4).background(JournalTheme.sage.opacity(0.45))
                    JournalRarity(rarity: rarity)
                }
                PlantNameText(name, rarity: rarity, announcesRarity: false)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.65).frame(height: nameHeight).padding(.horizontal, 6)
                Text("\(row.variantID?.capitalized ?? "Variant unavailable") · \(stage.map { "\($0.number)/4" } ?? "—")")
                    .font(.caption2).lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(JournalTheme.secondary)
                    .padding(.horizontal, 6)
                RecapWaterBar(row: row).padding(.horizontal, 7)
                HStack(spacing: 0) {
                    JournalInfoIcon(title: "Water gained", explanation: "", metric: "water")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gain).font(.caption).foregroundStyle((ExactAmount.integer(row.water) ?? 0) > 0
                            ? ActivityJournalTheme.addedText : JournalTheme.secondary)
                        Text(stageLabel).font(.caption2).foregroundStyle(JournalTheme.secondary)
                        if (ExactAmount.integer(row.skillWater) ?? 0) > 0 {
                            Text("incl. +\(JournalAmount.water(row.skillWater)) skill water")
                                .font(.caption2).foregroundStyle(JournalTheme.secondary)
                        } else if let plant = row.plant, plant.placement == nil {
                            Text("In Storage").font(.caption2).foregroundStyle(JournalTheme.secondary)
                        }
                    }.lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: max(44, footerHeight)).padding(.horizontal, 4)
            }.padding(.bottom, 6).clipShape(RoundedRectangle(cornerRadius: 16))
        }.accessibilityElement(children: .contain)
            .accessibilityLabel("\(name), \(row.variantID?.capitalized ?? "Variant unavailable"), \(stageLabel), \(gain)")
            .accessibilityIdentifier("recap.plant.\(row.id)")
    }
}

@MainActor
struct RecapWaterBar: View {
    let row: ActivityRecapRow
    var body: some View {
        Group {
            if let progress = RecapGrowthDisplay(row: row) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(JournalTheme.action).frame(width: geometry.size.width * CGFloat(progress.existing))
                        Rectangle().fill(ActivityJournalTheme.added).frame(width: geometry.size.width * CGFloat(progress.added))
                        Spacer(minLength: 0)
                    }.background(JournalTheme.sage).clipShape(Capsule())
                }.accessibilityElement(children: .ignore).accessibilityLabel("Growth to fully grown")
                    .accessibilityValue("\(progress.total.formatted(.percent.precision(.fractionLength(0)))), \(JournalAmount.water(row.water)) new water")
            } else {
                Capsule().fill(JournalTheme.sage).accessibilityLabel("Growth unavailable")
            }
        }.frame(height: 6).accessibilityIdentifier("recap.progress.\(row.id)")
    }
}
