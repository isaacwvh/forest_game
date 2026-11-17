import SwiftUI

struct GardenSkillGroup: Identifiable {
    let name: String
    let effects: [APISkillSummary.Effect]
    var availability: GardenAvailableSkill? = nil
    var id: String { name }
    var sources: Set<UUID> {
        if let availability = availability { return Set(availability.sourcePlantIds + availability.sourceItemIds) }
        return Set(effects.flatMap { $0.eligibleSourcePlantIds + ($0.eligibleSourceItemIds ?? []) })
    }
    var bonuses: [String] {
        let labels = effects.map { $0.bonusText + GardenStrategyCopy.recipientSuffix(rule(for: $0)) }
        return Array(Set(labels.isEmpty ? availability?.rules.map(\.description) ?? [] : labels)).sorted()
    }
    func rule(for effect: APISkillSummary.Effect) -> APIGardenSkillDefinition? {
        availability?.rules.first { $0.id == effect.skillId }
    }
    static func groups(_ summary: APISkillSummary?) -> [Self] {
        Dictionary(grouping: summary?.activeSkills ?? [], by: \.name)
            .map { Self(name: $0.key, effects: $0.value) }.sorted { $0.name < $1.name }
    }
    static func groups(in evaluation: GardenStrategyEvaluation) -> [Self] {
        guard let available = evaluation.availableSkills else { return groups(evaluation.skillSummary) }
        return available.map { skill in
            Self(name: skill.name, effects: evaluation.skillSummary.activeSkills.filter { $0.name == skill.name }, availability: skill)
        }
    }
}

struct GardenImpactRow: Identifiable, Equatable {
    let id: String
    let text: String
    let detail: String
    let direction: Int
}

enum GardenStrategyCopy {
    static func number(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }
    static func signed(_ value: Decimal) -> String {
        (value < 0 ? "−" : value > 0 ? "+" : "") + number(abs(value))
    }
    static func delta(_ before: String, _ after: String) -> String {
        guard let before = Decimal(string: before), let after = Decimal(string: after) else { return "Unavailable" }
        return signed((after - before) / 1_000_000)
    }
    static func recipientSuffix(_ rule: APIGardenSkillDefinition?) -> String {
        guard let selector = rule?.recipients else { return "" }
        if selector.tags.contains("understory") { return " to ferns and fungi" }
        var labels = selector.species.map { $0.replacingOccurrences(of: "-", with: " ").capitalized }
        labels += selector.tags.map { $0.replacingOccurrences(of: "_", with: " ") + " plants" }
        labels += selector.variants.map { $0.capitalized + " variants" }
        labels += selector.stages.map { $0 + " plants" }
        return labels.isEmpty ? "" : " to " + labels.joined(separator: ", ")
    }
    // Only surviving recipients can have a changed bonus. Recipient membership
    // alone must never announce an existing skill as added/removed/strengthened.
    static func impact(from before: GardenStrategyEvaluation, to after: GardenStrategyEvaluation) -> [GardenImpactRow] {
        var result: [GardenImpactRow] = []
        let a = (Decimal(string: before.totalAttractionMicroUnits) ?? 0) / 1_000_000
        let b = (Decimal(string: after.totalAttractionMicroUnits) ?? 0) / 1_000_000
        let attraction = b - a
        result.append(GardenImpactRow(id: "attraction", text: attraction == 0 ? "No attraction change" : "\(signed(attraction)) attraction",
            detail: attraction == 0 ? "" : "Attraction \(number(a)) → \(number(b))", direction: attraction < 0 ? -1 : attraction > 0 ? 1 : 0))
        let capacity = after.offlineCapacity - before.offlineCapacity
        if capacity != 0 {
            result.append(GardenImpactRow(id: "capacity", text: "\(signed(Decimal(capacity))) visitor storage",
                detail: "Visitor storage \(before.offlineCapacity) → \(after.offlineCapacity)", direction: capacity < 0 ? -1 : 1))
        }
        let old = Dictionary(uniqueKeysWithValues: GardenSkillGroup.groups(in: before).map { ($0.name, $0) })
        let new = Dictionary(uniqueKeysWithValues: GardenSkillGroup.groups(in: after).map { ($0.name, $0) })
        for name in Set(old.keys).symmetricDifference(Set(new.keys)).sorted() {
            let adding = new[name] != nil
            result.append(GardenImpactRow(id: "source/" + name, text: "\(adding ? "+" : "−") \(name)",
                detail: "", direction: adding ? 1 : -1))
        }
        let common = Set(before.skillSummary.growthFactors.map(\.plantId)).intersection(after.skillSummary.growthFactors.map(\.plantId))
        for name in Set(old.keys).intersection(new.keys).sorted() {
            let previous = old[name]!, next = new[name]!
            let slots = Dictionary(grouping: previous.effects + next.effects, by: slot)
            for key in slots.keys.sorted() {
                let sample = slots[key]![0]
                if sample.scope == "offline_capacity" { continue } // exact capped integer delta above
                let plantScope = ["water", "activity", "attraction_plant"].contains(sample.scope)
                let recipients: [UUID?] = plantScope ? common.sorted { $0.uuidString < $1.uuidString }.map { Optional($0) } : [nil]
                var seen = Set<String>()
                for recipient in recipients {
                    let oldAmount = magnitude(previous.effects, key: key, recipient: recipient)
                    let newAmount = magnitude(next.effects, key: key, recipient: recipient)
                    guard oldAmount != newAmount else { continue }
                    var change = newAmount - oldAmount
                    if sample.operation == "percent", let cap = cap(for: sample.scope, context: after.context) {
                        change = cappedChange(name: name, key: key, recipient: recipient,
                            before: before.skillSummary.activeSkills, after: after.skillSummary.activeSkills, cap: cap)
                    }
                    guard change != 0 else { continue }
                    let rule = next.rule(for: sample) ?? previous.rule(for: sample)
                    let unit = sample.operation == "percent" ? "%" : ""
                    let scale: Decimal = sample.operation == "percent" ? 100 : 1
                    let text = "\(signed(change * scale))\(unit) \(destination(sample))\(recipientSuffix(rule)) (\(name))"
                    guard seen.insert(text).inserted else { continue }
                    var detail = "\(name): \(number(oldAmount * scale))\(unit) → \(number(newAmount * scale))\(unit)"
                    for countRule in next.availability?.rules ?? [] {
                        if let countA = previous.availability?.qualifyingCounts[countRule.id],
                           let countB = next.availability?.qualifyingCounts[countRule.id], countA != countB {
                            let label = countRule.magnitude?.type == "per_species" ? "Distinct species" : "Qualifying plants"
                            detail += "; \(label) \(countA) → \(countB)"
                        }
                        let conditionKey = "condition:" + countRule.id
                        if let countA = previous.availability?.qualifyingCounts[conditionKey],
                           let countB = next.availability?.qualifyingCounts[conditionKey], countA != countB {
                            detail += "; Companions \(countA) → \(countB)"
                        }
                    }
                    result.append(GardenImpactRow(id: name + "/" + key + "/" + text, text: text, detail: detail, direction: change < 0 ? -1 : 1))
                }
            }
        }
        return result
    }
    static func changes(from before: GardenStrategyEvaluation?, to after: GardenStrategyEvaluation?) -> [String] {
        guard let before = before, let after = after else { return [] }
        return impact(from: before, to: after).filter { $0.id != "attraction" }.map(\.text)
    }
    private static func slot(_ effect: APISkillSummary.Effect) -> String {
        [effect.scope, effect.metric ?? "", effect.stepBand ?? "", effect.operation].joined(separator: "/")
    }
    private static func magnitude(_ effects: [APISkillSummary.Effect], key: String, recipient: UUID?) -> Decimal {
        effects.filter { effect in slot(effect) == key && (recipient == nil || effect.recipientPlantIds.contains(recipient!)) }
            .reduce(0) { $0 + (Decimal(string: $1.magnitude) ?? 0) }
    }
    private static func cappedChange(name: String, key: String, recipient: UUID?,
                                     before: [APISkillSummary.Effect], after: [APISkillSummary.Effect], cap: Decimal) -> Decimal {
        let names = Set((before + after).filter { slot($0) == key }.map(\.name))
        var changes: [(name: String, amount: Decimal)] = []
        for skill in names {
            let a = magnitude(before.filter { $0.name == skill }, key: key, recipient: recipient)
            let b = magnitude(after.filter { $0.name == skill }, key: key, recipient: recipient)
            if a != b { changes.append((skill, b - a)) }
        }
        // Apply losses before gains, then names in stable order. Every increment
        // is measured through the shared cap, so simultaneous changes cannot
        // double-count or lose the remaining available bonus.
        changes.sort { ($0.amount < 0) != ($1.amount < 0) ? $0.amount < 0 : $0.name < $1.name }
        var total = magnitude(before, key: key, recipient: recipient)
        for change in changes {
            let effective = min(cap, total + change.amount) - min(cap, total)
            total += change.amount
            if change.name == name { return effective }
        }
        return 0
    }
    private static func cap(for scope: String, context: APIStrategyContext) -> Decimal? {
        let value: String?
        switch scope {
        case "water": value = context.caps.waterBonus
        case "activity": value = context.caps.activityBonus
        case "attraction_plant": value = context.caps.plantAttractionBonus
        case "attraction_garden": value = context.caps.gardenAttractionBonus
        case "welcome_duration": value = "0.25"
        default: value = nil
        }
        return value.flatMap { Decimal(string: $0) }
    }
    private static func destination(_ effect: APISkillSummary.Effect) -> String {
        switch effect.scope {
        case "water": return "water"
        case "activity":
            if effect.metric == "steps" {
                return effect.stepBand == "after_2000" ? "water from steps after 2,000" :
                    effect.stepBand == "first_2000" ? "water from the first 2,000 steps" : "water from steps"
            }
            if let metric = effect.metric, metric.hasPrefix("workout_minutes.") {
                return "water from " + metric.replacingOccurrences(of: "workout_minutes.", with: "").replacingOccurrences(of: "_", with: " ") + " workouts"
            }
            switch effect.metric {
            case "walking_running_distance_km": return "water from walking and running"
            case "active_energy_kcal": return "water from active energy"
            case "flights_climbed": return "water from flights climbed"
            default: return "activity water"
            }
        case "welcome_duration": return "welcome time"
        case "daily_water": return "daily water per plant"
        default: return "attraction"
        }
    }
}

struct GardenActionImpact: View {
    let title: String
    let before: GardenStrategyEvaluation?
    let after: GardenStrategyEvaluation?
    var gardenOverlay = false
    @State private var expanded = false
    @State private var detailHeight: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var rows: [GardenImpactRow] {
        guard let before = before, let after = after else { return [] }
        return GardenStrategyCopy.impact(from: before, to: after)
    }
    var body: some View {
        let values = rows
        let identity = title + (before?.signature ?? "") + (after?.signature ?? "") + values.map(\.id).joined()
        let hasDetails = values.count > 3 || values.contains { !$0.detail.isEmpty }
        VStack(alignment: .leading, spacing: 3) {
            if values.isEmpty {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(JournalTheme.secondary)
                Text("Effects unavailable. Refresh your garden.").font(.caption).foregroundStyle(JournalTheme.secondary)
            } else {
                if hasDetails {
                    Button { expanded.toggle() } label: {
                        summary(values, expandable: true).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint(expanded ? "Hide impact details" : "Show impact details")
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed").accessibilityIdentifier("editor.impactDetails")
                } else { summary(values, expandable: false) }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(values.dropFirst(3))) { row in impactRow(row) }
                            ForEach(values.filter { !$0.detail.isEmpty }) { row in
                                Text(row.detail).font(.caption).foregroundStyle(JournalTheme.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: GardenImpactDetailHeight.self, value: geometry.size.height)
                            })
                    }.frame(height: min(detailHeight, verticalSizeClass == .compact ? 72 : 160))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(gardenOverlay ? JournalTheme.paper.opacity(reduceTransparency ? 1 : 0.08) : JournalTheme.sage.opacity(0.3),
                in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain).accessibilityIdentifier("editor.actionImpact")
            .onChange(of: identity) { _ in expanded = false }
            .onPreferenceChange(GardenImpactDetailHeight.self) { detailHeight = $0 }
    }
    private func summary(_ values: [GardenImpactRow], expandable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if values.count > 3 && !expanded { Text("\(values.count - 3) more").font(.caption2) }
                if expandable { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2) }
            }.foregroundStyle(JournalTheme.secondary)
            ForEach(Array(values.prefix(3))) { row in impactRow(row) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func impactRow(_ row: GardenImpactRow) -> some View {
        Text(row.text).font(.subheadline).monospacedDigit()
            .foregroundStyle(row.direction < 0 ? JournalTheme.danger : row.direction > 0 ? JournalTheme.action : JournalTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GardenImpactDetailHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
struct GardenStrategyPanel: View {
    @ObservedObject var store: GardenEditorStore
    let openSkills: () -> Void
    @State private var now = Date()
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let value = store.strategyPreview {
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    metric("Attraction", icon: "attraction", value: GardenStrategyCopy.number((Decimal(string: value.totalAttractionMicroUnits) ?? 0) / 1_000_000), id: "editor.attraction")
                    metric("Visitor storage", icon: "offline_capacity", value: value.offlineCapacity.formatted(), id: "editor.offlineCapacity")
                    Button(action: openSkills) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Skills").font(.caption).foregroundStyle(JournalTheme.secondary)
                            HStack(spacing: 5) {
                                Text(String(GardenSkillGroup.groups(in: value).count)).font(.headline).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    }.buttonStyle(.plain).accessibilityLabel("Garden skills")
                        .accessibilityIdentifier("editor.skills").accessibilityValue("Closed")
                }.accessibilityIdentifier("editor.strategyMetrics")
                if store.showingCached || !value.context.fresh(at: now) {
                    Text("Saved context. Refresh for current effects.").font(.caption)
                    refreshButton
                }
            } else {
                HStack {
                    Text("Garden effects unavailable").font(.caption)
                    Button("Skills", action: openSkills).buttonStyle(.journalQuiet).accessibilityIdentifier("editor.skills")
                    refreshButton
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).tint(JournalTheme.action)
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    private func metric(_ title: String, icon: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(JournalTheme.secondary)
            QuantityLabel(metric: icon, text: value).font(.headline).monospacedDigit()
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }
    private var refreshButton: some View {
        Button("Refresh effects") { Task { await store.refresh() } }.buttonStyle(.journalQuiet)
            .disabled(store.connectionBusy || store.pending != nil)
    }
}

@MainActor
struct GardenSkillsPage: View {
    @ObservedObject var store: GardenEditorStore
    let close: () -> Void
    private var evaluation: GardenStrategyEvaluation? { store.editing ? store.strategyPreview : store.savedStrategy }
    private var plants: [APIOwnedPlant] { store.editing ? store.strategyPlants : store.confirmed?.plants ?? [] }
    private var items: [APIOwnedItem] { store.editing ? store.strategyItems : store.confirmed?.items ?? [] }
    private var groups: [GardenSkillGroup] {
        if let evaluation = evaluation { return GardenSkillGroup.groups(in: evaluation) }
        let available = GardenAvailableSkill.collect(plants: plants, items: items)
        let effective = store.editing ? [] : GardenSkillGroup.groups(store.confirmed?.skillSummary)
        let names = Set(available.map(\.name)).union(effective.map(\.name))
        return names.sorted().map { name in
            GardenSkillGroup(name: name, effects: effective.first { $0.name == name }?.effects ?? [],
                availability: available.first { $0.name == name })
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.editing {
                    Text(store.editCandidateID != nil ? "Placement preview" : store.hasDraftChanges ? "Unsaved garden" : "Saved garden")
                        .font(.caption).foregroundStyle(JournalTheme.secondary)
                }
                if groups.isEmpty { Text("No active skills").foregroundStyle(JournalTheme.secondary) }
                ForEach(groups) { group in
                    skill(group).padding(12)
                        .background(JournalTheme.sage.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }
                if let evaluation = evaluation {
                    ForEach(evaluation.limitNotices ?? [], id: \.self) { Text($0).font(.caption) }
                    if evaluation.skillSummary.capReached {
                        DisclosureGroup("Boost cap reached") { Text(evaluation.skillSummary.caps.description).font(.footnote) }
                    }
                } else { Text("Current effects unavailable. Refresh your garden.").font(.caption) }
                if let grants = store.confirmed?.dailyWater, !grants.isEmpty {
                    JournalSectionHeading(title: "Recent Morning Rain")
                    ForEach(grants) { grant in Text("\(grant.gameDate): +\(grant.water) water across \(grant.plantCount) plants").font(.callout) }
                }
                if store.showingCached { Text("Last confirmed context").font(.caption).foregroundStyle(JournalTheme.secondary) }
            }.padding(20)
        }.navigationTitle("Garden skills").navigationBarTitleDisplayMode(.inline)
            .background(JournalPageBackground().ignoresSafeArea()).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .accessibilityIdentifier("garden.skillsPage")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .buttonStyle(.journalIcon).accessibilityLabel("Close garden skills").accessibilityIdentifier("garden.skills.close")
                }
            }
    }
    private func skill(_ group: GardenSkillGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                let descriptions = (group.availability?.rules.map(\.description) ?? []) + group.effects.map(\.description)
                ForEach(Array(Set(descriptions)).sorted(), id: \.self) { Text($0).font(.caption) }
                Text("Conditions: \(conditions(group))").font(.caption)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Sources:").fixedSize()
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sources(group)) { source in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("(\(source.kind))").fixedSize()
                                PlantNameText(source.name, rarity: source.rarity)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                        }
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                .foregroundStyle(JournalTheme.secondary).padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.headline)
                ForEach(group.bonuses, id: \.self) { Text($0).font(.subheadline).foregroundStyle(JournalTheme.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("garden.skill.\(group.effects.first?.skillId ?? group.availability?.rules.first?.id ?? group.name)")
    }
    private func conditions(_ group: GardenSkillGroup) -> String {
        var values: [String] = []
        for rule in group.availability?.rules ?? [] {
            if let condition = rule.condition {
                let names = condition.selector.species.map { id in
                    store.catalogue?.species.first { $0.speciesId == id }?.displayName ?? id.capitalized
                }
                let label = names.isEmpty ? (condition.selector.tags.isEmpty ? "Companions" : condition.selector.tags.map { $0.capitalized }.joined(separator: " + ")) : names.joined(separator: " or ")
                let count = group.availability?.qualifyingCounts["condition:" + rule.id] ?? 0
                values.append("\(label): \(count) / \(condition.minimum)")
            }
            if let count = group.availability?.qualifyingCounts[rule.id] {
                values.append("\(rule.magnitude?.type == "per_species" ? "Distinct species" : "Qualifying plants"): \(count)")
            }
            if rule.stepBand == "first_2000" { values.append("First 2,000 steps each day") }
            if rule.stepBand == "after_2000" { values.append("Steps after 2,000 each day") }
            if rule.magnitude?.type == "daily_flights" {
                values.append(evaluation.map { "Flights today: \($0.context.dailyFlights)" } ?? "Flights synced today")
            }
        }
        if group.name == "Morning Rain" { values.append("Next game-day reset after saving") }
        if values.isEmpty {
            values.append(sources(group).contains { $0.kind == "Plant" } ? "Fully grown and planted" : "While placed")
        }
        if group.sources.count > 1 { values.append("Duplicates do not stack") }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }.joined(separator: "; ")
    }
    private struct SkillSource: Identifiable {
        let id: UUID
        let kind: String
        let name: String
        let rarity: String?
    }
    private func sources(_ group: GardenSkillGroup) -> [SkillSource] {
        group.sources.compactMap { id -> SkillSource? in
            if let plant = plants.first(where: { $0.id == id }) {
                let name = store.catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName ?? plant.speciesId.capitalized
                return SkillSource(id: id, kind: "Plant", name: name, rarity: store.catalogue?.rarity(for: plant.speciesId))
            }
            guard let item = items.first(where: { $0.id == id }) else { return nil }
            return SkillSource(id: id, kind: "Item", name: item.displayName, rarity: item.rarity)
        }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }
}
