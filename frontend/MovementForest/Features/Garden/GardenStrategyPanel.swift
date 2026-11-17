import SwiftUI

struct GardenSkillGroup: Identifiable {
    let name: String
    let effects: [APISkillSummary.Effect]
    var id: String { name }
    var bonuses: [String] {
        let workouts = effects.filter { $0.scope == "activity" && ($0.metric?.hasPrefix("workout_minutes.") ?? false) }
        if workouts.count > 1, Set(workouts.map(\.magnitude)).count == 1, let first = workouts.first,
           let amount = Decimal(string: first.magnitude) {
            let value = (amount * 100).formatted(.number.precision(.fractionLength(0...2)))
            return Array(Set(effects.filter { !($0.metric?.hasPrefix("workout_minutes.") ?? false) }.map(\.bonusText) +
                ["+\(value)% water from workouts"])).sorted()
        }
        return Array(Set(effects.map(\.bonusText))).sorted()
    }
    var sources: Set<UUID> { Set(effects.flatMap { $0.eligibleSourcePlantIds + ($0.eligibleSourceItemIds ?? []) }) }
    var valueSignature: String {
        Array(Set(effects.map { [$0.scope, $0.metric ?? "", $0.stepBand ?? "", $0.magnitude].joined(separator: "/") })).sorted().joined(separator: ",")
    }
    static func groups(_ summary: APISkillSummary?) -> [Self] {
        Dictionary(grouping: summary?.activeSkills ?? [], by: \.name)
            .map { Self(name: $0.key, effects: $0.value) }.sorted { $0.name < $1.name }
    }
}

enum GardenStrategyCopy {
    static func delta(_ before: String, _ after: String) -> String {
        guard let before = Decimal(string: before), let after = Decimal(string: after) else { return "" }
        let change = (after - before) / 1_000_000
        return change == 0 ? "No change" : (change > 0 ? "+" : "") + change.formatted(.number.precision(.fractionLength(0...2)))
    }
    static func changes(from before: GardenStrategyEvaluation?, to after: GardenStrategyEvaluation?) -> [String] {
        guard let before = before, let after = after else { return [] }
        let old = Dictionary(uniqueKeysWithValues: GardenSkillGroup.groups(before.skillSummary).map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: GardenSkillGroup.groups(after.skillSummary).map { ($0.id, $0) })
        return Set(old.keys).union(new.keys).sorted().compactMap { name in
            guard let next = new[name] else { return "Removes \(name)" }
            guard let previous = old[name] else { return "Activates \(name)" }
            if next.valueSignature != previous.valueSignature {
                return "\(name): \(previous.bonuses.joined(separator: ", ")) → \(next.bonuses.joined(separator: ", "))"
            }
            return nil
        }
    }
}

struct GardenInactiveSkillGroup: Identifiable {
    let name: String
    let rule: APIGardenSkillDefinition
    let sourceIsAdult: Bool
    var id: String { name }
    static func groups(plants: [APIOwnedPlant], items: [APIOwnedItem], summary: APISkillSummary) -> [Self] {
        let activeNames = Set(summary.activeSkills.map(\.name))
        let plantRules = plants.flatMap { plant in
            (plant.gardenSkills ?? []).map { Self(name: $0.name, rule: $0, sourceIsAdult: plant.growthStage == .adult) }
        }
        let itemRules = items.flatMap { item in
            (item.strategyRules?.effects ?? []).map { Self(name: $0.name, rule: $0, sourceIsAdult: true) }
        }
        return Dictionary(grouping: (plantRules + itemRules).filter { !activeNames.contains($0.name) }, by: \.name)
            .compactMap { _, sources in sources.first(where: { $0.sourceIsAdult }) ?? sources.first }
            .sorted { $0.name < $1.name }
    }
}

struct GardenActionImpact: View {
    let title: String
    let before: GardenStrategyEvaluation?
    let after: GardenStrategyEvaluation?
    var showsSkillChanges = true
    var body: some View {
        if let before = before, let after = after,
           showsSkillChanges || before.totalAttractionMicroUnits != after.totalAttractionMicroUnits || before.offlineCapacity != after.offlineCapacity {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if before.totalAttractionMicroUnits != after.totalAttractionMicroUnits {
                    QuantityLabel(metric: "attraction", text: "Attraction \(GardenStrategyCopy.delta(before.totalAttractionMicroUnits, after.totalAttractionMicroUnits))")
                        .font(.callout).monospacedDigit()
                }
                if before.offlineCapacity != after.offlineCapacity {
                    QuantityLabel(metric: "offline_capacity", text: "Offline capacity \(before.offlineCapacity.formatted()) → \(after.offlineCapacity.formatted())")
                        .font(.callout).monospacedDigit()
                }
                if showsSkillChanges {
                    let changes = GardenStrategyCopy.changes(from: before, to: after)
                    ForEach(changes, id: \.self) { Text($0).font(.callout) }
                    if changes.isEmpty { Text("Skills unchanged").font(.caption).foregroundStyle(JournalTheme.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine).accessibilityIdentifier("editor.actionImpact")
        }
    }
}

@MainActor
struct GardenStrategyPanel: View {
    @ObservedObject var store: GardenEditorStore
    @State private var expanded = true
    @State private var now = Date()
    @Environment(\.dynamicTypeSize) private var textSize
    private var value: GardenStrategyEvaluation? { store.strategyPreview }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value = value {
                metrics(value).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                if store.editCandidateID != nil {
                    GardenActionImpact(title: "If applied", before: store.draftStrategy, after: value, showsSkillChanges: false)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                } else if let id = store.selectedID {
                    GardenActionImpact(title: "If stored", before: store.draftStrategy, after: store.strategyIfStored(id), showsSkillChanges: false)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                }
                if store.showingCached || !value.context.fresh(at: now) {
                    Text("Saved context. Refresh for current effects.").font(.caption)
                    refreshButton
                }
                Button { expanded.toggle() } label: {
                    HStack {
                        Text("Garden skills")
                        Text(String(GardenSkillGroup.groups(value.skillSummary).count)).monospacedDigit()
                        Spacer()
                        Text(store.editCandidateID != nil ? "Preview" : store.hasDraftChanges ? "Draft" : "Saved")
                            .font(.caption).foregroundStyle(JournalTheme.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                    }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("editor.skills")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .fixedSize(horizontal: false, vertical: true)
                if expanded {
                    ScrollView {
                        skillList(value).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(-1).accessibilityIdentifier("editor.skillsScroll")
                }
            } else {
                Label("Garden effects unavailable", systemImage: "info.circle").font(.subheadline)
                refreshButton
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).tint(JournalTheme.action)
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    private func metrics(_ value: GardenStrategyEvaluation) -> some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            metric("Attraction", icon: "attraction", value: JournalAmount.water(value.totalAttractionMicroUnits),
                change: store.savedStrategy.flatMap { saved in
                    saved.totalAttractionMicroUnits == value.totalAttractionMicroUnits ? nil : GardenStrategyCopy.delta(saved.totalAttractionMicroUnits, value.totalAttractionMicroUnits)
                }, identifier: "editor.attraction")
            metric("Offline capacity", icon: "offline_capacity", value: value.offlineCapacity.formatted(),
                change: store.savedStrategy.flatMap { saved in
                    let difference = value.offlineCapacity - saved.offlineCapacity
                    return difference == 0 ? nil : (difference > 0 ? "+" : "") + difference.formatted()
                }, identifier: "editor.offlineCapacity")
        }.accessibilityIdentifier("editor.strategyMetrics")
    }
    private func metric(_ title: String, icon: String, value: String, change: String?, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            QuantityIcon(metric: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(JournalTheme.secondary)
                Text(value).font(.headline).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                if let change = change { Text("\(change) from saved").font(.caption).monospacedDigit() }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
    private var refreshButton: some View {
        Button("Refresh effects") { Task { await store.refresh() } }.buttonStyle(.journalQuiet)
            .disabled(store.connectionBusy || store.pending != nil)
    }
    private func skillList(_ value: GardenStrategyEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let groups = GardenSkillGroup.groups(value.skillSummary)
            if groups.isEmpty { Text("No active skills").font(.callout) }
            ForEach(groups) { GardenSkillDisclosure(group: $0, store: store, evaluation: value) }
            let changes = GardenStrategyCopy.changes(from: store.savedStrategy, to: value)
            if !changes.isEmpty {
                Divider()
                ForEach(changes, id: \.self) { Text($0).font(.caption) }
            }
            let inactive = GardenInactiveSkillGroup.groups(plants: store.strategyPlants, items: store.strategyItems, summary: value.skillSummary)
            if !inactive.isEmpty {
                Divider()
                DisclosureGroup("Inactive skills (\(inactive.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(inactive) { skill in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name).font(.callout.weight(.semibold))
                                if !skill.sourceIsAdult {
                                    Text("Requires a fully grown source").font(.caption)
                                } else if let condition = skill.rule.condition {
                                    Text("Companions \(store.strategyPlants.filter { condition.selector.matches($0) }.count) / \(condition.minimum)").font(.caption)
                                } else if skill.rule.magnitude?.type == "daily_flights" {
                                    Text("Requires flights synced today").font(.caption)
                                } else { Text("Requirements not met").font(.caption) }
                                Text(skill.rule.description).font(.caption).foregroundStyle(JournalTheme.secondary)
                            }
                        }
                    }.padding(.top, 8)
                }.font(.subheadline).accessibilityIdentifier("editor.inactiveSkills")
            }
            if let water = value.skillSummary.waterHeadline { Text(water).font(.callout).monospacedDigit() }
            ForEach(value.limitNotices ?? [], id: \.self) { Text($0).font(.caption) }
            if value.skillSummary.capReached { Text(value.skillSummary.caps.description).font(.caption) }
        }
    }
}

@MainActor
struct GardenSkillDisclosure: View {
    let group: GardenSkillGroup
    @ObservedObject var store: GardenEditorStore
    let evaluation: GardenStrategyEvaluation
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Set(group.effects.map(\.description))).sorted(), id: \.self) { Text($0).font(.caption) }
                ForEach(group.effects, id: \.id) { effect in
                    if effect.system == "growth", effect.scope != "daily_water" {
                        Text("\(effect.bonusText) for \(effect.recipientPlantIds.count) planted plants").font(.caption)
                    }
                }
                if !sourceNames.isEmpty { Text("Sources: \(sourceNames.joined(separator: ", "))").font(.caption) }
                if group.sources.count > 1 { Text("Shared bonus. Duplicates do not add together.").font(.caption) }
                ForEach(countRules, id: \.id) { rule in
                    if let magnitude = rule.magnitude {
                        let selected = (store.strategyPlants).filter { magnitude.selector?.matches($0) ?? true }
                        let count = magnitude.type == "per_species" ? Set(selected.map(\.speciesId)).count : selected.count
                        Text(countDescription(magnitude, count: count)).font(.caption).monospacedDigit()
                    }
                }
                if group.effects.contains(where: { $0.scope == "daily_water" }) {
                    Text("Applies at the next game-day reset after saving.").font(.caption)
                }
                if evaluation.skillSummary.capReached {
                    Text("Some growth bonuses are capped. The preview includes limits.").font(.caption)
                }
            }.foregroundStyle(JournalTheme.secondary).padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.callout.weight(.semibold))
                ForEach(group.bonuses, id: \.self) { Text($0).font(.caption).foregroundStyle(JournalTheme.secondary) }
            }
        }.accessibilityIdentifier("garden.skill.\(group.effects.first?.skillId ?? group.name)")
    }
    private func countDescription(_ magnitude: APIStrategyMagnitude, count: Int) -> String {
        let title = magnitude.type == "per_species" ? "Distinct species" : "Qualifying plants"
        guard let maximum = magnitude.maximum.flatMap({ Decimal(string: $0) }),
              let unit = Decimal(string: magnitude.value), unit > 0 else { return "\(title): \(count)" }
        var ratio = maximum / unit, rounded = Decimal()
        NSDecimalRound(&rounded, &ratio, 0, .up)
        let threshold = NSDecimalNumber(decimal: rounded).intValue
        return "\(title) \(min(count, threshold)) / \(threshold)"
    }
    private var sourceNames: [String] {
        group.sources.compactMap { id -> String? in
            if let plant = store.ownedCopy(id) {
                return store.catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName ?? plant.speciesId.capitalized
            }
            return store.draft?.items.first { $0.id == id }?.displayName
        }.sorted()
    }
    private var countRules: [APIGardenSkillDefinition] {
        let rules = (store.strategyPlants).flatMap { $0.gardenSkills ?? [] } +
            (store.strategyItems).flatMap { $0.strategyRules?.effects ?? [] }
        var seen = Set<String>()
        return rules.filter { $0.name == group.name && ["per_species", "per_copy"].contains($0.magnitude?.type ?? "") && seen.insert($0.id).inserted }
    }
}
