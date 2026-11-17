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

struct GardenActionImpact: View {
    let title: String
    let before: GardenStrategyEvaluation?
    let after: GardenStrategyEvaluation?
    var body: some View {
        if let before = before, let after = after {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if before.totalAttractionMicroUnits != after.totalAttractionMicroUnits {
                    Text("Attraction \(GardenStrategyCopy.delta(before.totalAttractionMicroUnits, after.totalAttractionMicroUnits))").font(.callout).monospacedDigit()
                }
                if before.offlineCapacity != after.offlineCapacity {
                    Text("Visitor storage \(before.offlineCapacity) → \(after.offlineCapacity)").font(.callout).monospacedDigit()
                }
                let changes = GardenStrategyCopy.changes(from: before, to: after)
                ForEach(changes, id: \.self) { Text($0).font(.callout) }
                if changes.isEmpty { Text("Skills unchanged").font(.caption).foregroundStyle(JournalTheme.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine).accessibilityIdentifier("editor.actionImpact")
        }
    }
}

@MainActor
struct GardenStrategyPanel: View {
    @ObservedObject var store: GardenEditorStore
    @State private var expanded = false
    @State private var now = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var value: GardenStrategyEvaluation? { store.strategyPreview }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = value {
                HStack(alignment: .firstTextBaseline) {
                    Label("Attraction", systemImage: "sparkles")
                    Text(JournalAmount.water(value.totalAttractionMicroUnits)).fontWeight(.semibold).monospacedDigit()
                    Spacer(minLength: 4)
                    if let saved = store.savedStrategy {
                        Text(GardenStrategyCopy.delta(saved.totalAttractionMicroUnits, value.totalAttractionMicroUnits)).font(.caption).monospacedDigit()
                    }
                }.font(.subheadline).accessibilityElement(children: .combine).accessibilityIdentifier("editor.attraction")
                DisclosureGroup(isExpanded: $expanded) { skillList(value) } label: {
                    HStack {
                        Text("Garden skills")
                        Text(String(GardenSkillGroup.groups(value.skillSummary).count)).monospacedDigit()
                        Spacer()
                        Text(store.editCandidateID == nil ? (store.hasDraftChanges ? "Draft" : "Saved") : "Preview")
                            .font(.caption).foregroundStyle(JournalTheme.secondary)
                    }.font(.subheadline)
                }.accessibilityIdentifier("editor.skills")
                if store.showingCached || !value.context.fresh(at: now) {
                    Text("Saved context. Connect to refresh effects.").font(.caption)
                    refreshButton
                } else if !expanded, let change = GardenStrategyCopy.changes(from: store.savedStrategy, to: value).first {
                    Text(change).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("Garden effects unavailable", systemImage: "info.circle").font(.subheadline)
                refreshButton
            }
        }.tint(JournalTheme.action)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: value?.signature)
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    private var refreshButton: some View {
        Button("Refresh effects") { Task { await store.refresh() } }.buttonStyle(.journalQuiet)
            .disabled(store.connectionBusy || store.pending != nil)
    }
    private func skillList(_ value: GardenStrategyEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let groups = GardenSkillGroup.groups(value.skillSummary)
            if groups.isEmpty { Text("No active skills").font(.callout) }
            ForEach(groups) { GardenSkillDisclosure(group: $0, store: store, evaluation: value) }
            let removed = GardenSkillGroup.groups(store.savedStrategy?.skillSummary).filter { old in !groups.contains { $0.id == old.id } }
            ForEach(removed) { Label("\($0.name) removed", systemImage: "minus.circle").font(.callout) }
            inactiveSkills(value)
            if let water = value.skillSummary.waterHeadline { Text(water).font(.callout).monospacedDigit() }
            ForEach(value.limitNotices ?? [], id: \.self) { Text($0).font(.caption) }
            if value.skillSummary.capReached { Text(value.skillSummary.caps.description).font(.caption) }
            if value.context.baseCapacity > 0 {
                LabeledContent("Visitor storage", value: String(value.offlineCapacity)).font(.callout)
                Text("Earned visits are kept when capacity falls.").font(.caption).foregroundStyle(JournalTheme.secondary)
            }
        }.padding(.top, 8)
    }
    @ViewBuilder private func inactiveSkills(_ value: GardenStrategyEvaluation) -> some View {
        let names = Set(value.skillSummary.activeSkills.map(\.name))
        let plants = store.strategyPlants
        let rules = plants.flatMap { plant in (plant.gardenSkills ?? []).map { (plant, $0) } }
        let inactive = Dictionary(grouping: rules.filter { !names.contains($0.1.name) }, by: { $0.1.name })
        ForEach(inactive.keys.sorted(), id: \.self) { name in
            if let (source, rule) = inactive[name]?.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.callout.weight(.semibold))
                    if source.growthStage != .adult {
                        Text("Requires a fully grown source").font(.caption)
                    } else if let condition = rule.condition {
                        Text("Companions \(plants.filter { condition.selector.matches($0) }.count) / \(condition.minimum)").font(.caption)
                    } else if rule.magnitude?.type == "daily_flights" {
                        Text("Requires flights synced today").font(.caption)
                    } else { Text("Requirements not met").font(.caption) }
                    Text(rule.description).font(.caption).foregroundStyle(JournalTheme.secondary)
                }
            }
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
