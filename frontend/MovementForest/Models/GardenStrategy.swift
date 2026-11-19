import Foundation

struct APIStrategySelector: Codable, Equatable {
    var species: [String] = []
    var variants: [String] = []
    var stages: [String] = []
    var tags: [String] = []
    func matches(_ plant: APIOwnedPlant) -> Bool {
        (species.isEmpty || species.contains(plant.speciesId)) &&
        (variants.isEmpty || variants.contains(plant.variantId)) &&
        (stages.isEmpty || stages.contains(plant.growthStage.rawValue)) &&
        (tags.isEmpty || Set(tags).isSubset(of: Set(plant.gameplayTags ?? [])))
    }
}
struct APIStrategyCondition: Codable, Equatable {
    let type: String
    let selector: APIStrategySelector
    let minimum: Int
}
struct APIStrategyMagnitude: Codable, Equatable {
    let type: String
    let value: String
    var selector: APIStrategySelector? = nil
    var maximum: String? = nil
}
struct APIItemStrategyRules: Codable, Equatable {
    let profileId: String
    let profileVersion: Int
    let effects: [APIGardenSkillDefinition]
    var dailyGrant: DailyGrant? = nil
    var triggeredGrants: [TriggeredGrant]? = nil
    struct DailyGrant: Codable, Equatable { let water: String }
    struct TriggeredGrant: Codable, Equatable {
        let type: String
        let family: String
        let name: String
        let tiers: [Tier]
        struct Tier: Codable, Equatable { let steps: Int; let water: String }
    }
}
struct APIStrategyContext: Codable, Equatable {
    let schemaVersion: Int
    let policyVersion: String
    let caps: APISkillSummary.Caps
    let dailyFlights: Int
    let baseCapacity: Int
    let maximumCapacity: Int
    let capacityFlatMultiplier: Int
    let welcomeSeconds: Int
    let gameDate: String
    let validUntil: String
    var ruleVersion: String? = nil
    var fresh: Bool { fresh(at: Date()) }
    func fresh(at now: Date) -> Bool {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = parser.date(from: validUntil) ?? ISO8601DateFormatter().date(from: validUntil)
        return expiry.map { $0 > now } ?? false
    }
}

struct GardenStrategyEvaluation: Codable, Equatable {
    let totalAttractionMicroUnits: String
    let skillSummary: APISkillSummary
    let offlineCapacity: Int
    let context: APIStrategyContext
    var fingerprint: String? = nil
    var limitNotices: [String]? = nil
    // Presentation eligibility is independent of whether a condition currently
    // produces a winning effect. It never changes the server proof/signature.
    var availableSkills: [GardenAvailableSkill]? = nil
    // Compare effective results, not emitter tie identities or wire ordering.
    var signature: String {
        let effects = skillSummary.activeSkills.map { effect in
            [effect.skillId, effect.scope, effect.metric ?? "", effect.stepBand ?? "",
             effect.stackingGroup, Self.normal(effect.magnitude),
             effect.recipientPlantIds.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")].joined(separator: "/")
        }.sorted().joined(separator: "|")
        let factors = skillSummary.growthFactors.map { row in
            row.plantId.uuidString.lowercased() + ":" + Self.normal(row.waterFactor) + ":" +
            row.activityFactors.keys.sorted().map { $0 + "=" + Self.normal(row.activityFactors[$0]!) }.joined(separator: ",")
        }.sorted().joined(separator: "|")
        return [Self.normal(totalAttractionMicroUnits), String(offlineCapacity), effects, factors].joined(separator: "#")
    }
    private static func normal(_ text: String) -> String {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")).map { NSDecimalNumber(decimal: $0).stringValue } ?? text
    }
}

struct GardenAvailableSkill: Codable, Equatable, Identifiable {
    let name: String
    let rules: [APIGardenSkillDefinition]
    let sourcePlantIds: [UUID]
    let sourceItemIds: [UUID]
    var qualifyingCounts: [String: Int] = [:]
    var id: String { name }

    static func collect(plants: [APIOwnedPlant], items: [APIOwnedItem]) -> [Self] {
        var definitions: [String: [APIGardenSkillDefinition]] = [:]
        var plantSources: [String: Set<UUID>] = [:], itemSources: [String: Set<UUID>] = [:]
        for plant in plants where plant.growthStage == .adult {
            for rule in plant.gardenSkills ?? [] {
                definitions[rule.name, default: []].append(rule)
                plantSources[rule.name, default: []].insert(plant.id)
            }
        }
        for item in items {
            for rule in item.strategyRules?.effects ?? [] {
                definitions[rule.name, default: []].append(rule)
                itemSources[rule.name, default: []].insert(item.id)
            }
            if item.strategyRules?.dailyGrant != nil {
                definitions["Morning Rain", default: []] += []
                itemSources["Morning Rain", default: []].insert(item.id)
            }
            for trigger in item.strategyRules?.triggeredGrants ?? [] {
                definitions[trigger.name, default: []] += []
                itemSources[trigger.name, default: []].insert(item.id)
            }
        }
        return definitions.keys.sorted().map { name in
            var seen = Set<String>()
            let rules = definitions[name, default: []].filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
            var counts: [String: Int] = [:]
            for rule in rules {
                if let magnitude = rule.magnitude, ["per_copy", "per_species"].contains(magnitude.type) {
                    let selected = plants.filter { magnitude.selector?.matches($0) ?? true }
                    counts[rule.id] = magnitude.type == "per_species" ? Set(selected.map(\.speciesId)).count : selected.count
                }
                if let condition = rule.condition {
                    counts["condition:" + rule.id] = plants.filter { condition.selector.matches($0) }.count
                }
            }
            return Self(name: name, rules: rules,
                sourcePlantIds: (plantSources[name] ?? []).sorted { $0.uuidString < $1.uuidString },
                sourceItemIds: (itemSources[name] ?? []).sorted { $0.uuidString < $1.uuidString }, qualifyingCounts: counts)
        }
    }
}

/// Pure counterpart to SkillSnapshot. Decimal arithmetic stays exact for the
/// bounded micro-unit amounts and six-place factors accepted by the server.
/// Unknown or incomplete rules fail closed instead of guessing a bonus.
enum GardenStrategyEvaluator {
    private struct Source {
        let id: UUID
        let item: Bool
        let profile: String
        let version: Int
        let rules: [APIGardenSkillDefinition]
    }
    private struct Candidate {
        let source: Source
        let rule: APIGardenSkillDefinition
        let value: Decimal
        var order: String { rule.id + "/" + source.profile + "/" + String(format: "%020d", source.version) + "/" + source.id.uuidString.lowercased() }
    }
    static func evaluate(plants: [APIOwnedPlant], items: [APIOwnedItem], context: APIStrategyContext) throws -> GardenStrategyEvaluation {
        guard context.schemaVersion == 1 else { throw unavailable }
        let caps = context.caps
        let activityCap = try amount(caps.activityBonus), waterCap = try amount(caps.waterBonus)
        let plantCap = try amount(caps.plantAttractionBonus), gardenCap = try amount(caps.gardenAttractionBonus)
        let totalCap = try amount(caps.totalAttractionBonus), flatCap = try amount(caps.flatAttractionPoints)
        let flatFraction = try amount(caps.flatAttractionBaseFraction), capacityCap = try amount(caps.capacityBonus)
        guard let flatCapacity = caps.flatCapacity else { throw unavailable }
        var sources: [Source] = []
        for plant in plants {
            guard let rules = plant.gardenSkills, let pinned = plant.pinnedProfiles,
                  plant.baseAttractionMicroUnits != nil, plant.gameplayTags != nil else { throw unavailable }
            if plant.growthStage == .adult {
                sources.append(Source(id: plant.id, item: false, profile: pinned.behaviour.id, version: pinned.behaviour.version, rules: rules))
            }
        }
        for item in items {
            guard let rules = item.strategyRules else { throw unavailable }
            sources.append(Source(id: item.id, item: true, profile: rules.profileId, version: rules.profileVersion, rules: rules.effects))
        }
        func selected(_ selector: APIStrategySelector?) -> [APIOwnedPlant] { plants.filter { selector?.matches($0) ?? true } }
        func candidates(_ band: String?) throws -> [Candidate] {
            try sources.flatMap { source -> [Candidate] in
                try source.rules.compactMap { rule in
                    guard [1, 2].contains(rule.componentVersion ?? 0), rule.minimumStage == "adult",
                          ["growth", "visitors"].contains(rule.system ?? ""),
                          ["activity", "water", "attraction_plant", "attraction_garden", "offline_capacity", "welcome_duration"].contains(rule.scope ?? ""),
                          ["all_planted_plants", "selected_plants", "garden"].contains(rule.target ?? ""),
                          ["percent", "flat"].contains(rule.operation ?? ""),
                          rule.stackingRule == "strongest", rule.stackingGroup != nil,
                          let magnitude = rule.magnitude else { throw unavailable }
                    if let stepBand = rule.stepBand, stepBand != band { return nil }
                    if let condition = rule.condition {
                        guard condition.type == "placed_count" else { throw unavailable }
                        if selected(condition.selector).count < condition.minimum { return nil }
                    }
                    var value = try amount(magnitude.value)
                    switch magnitude.type {
                    case "fixed": break
                    case "per_copy", "per_species", "daily_flights":
                        let count: Int
                        if magnitude.type == "daily_flights" { count = context.dailyFlights }
                        else if magnitude.type == "per_species" { count = Set(selected(magnitude.selector).map(\.speciesId)).count }
                        else { count = selected(magnitude.selector).count }
                        value = min(value * Decimal(count), try amount(magnitude.maximum))
                    default: throw unavailable
                    }
                    return value > 0 ? Candidate(source: source, rule: rule, value: value) : nil
                }
            }
        }
        let regular = try candidates(nil)
        func resolve(_ scope: String, _ recipient: APIOwnedPlant? = nil, _ metric: String? = nil,
                     _ operation: String = "percent", _ entries: [Candidate]? = nil) -> [(Candidate, [Candidate])] {
            let eligible = (entries ?? regular).filter { entry in
                entry.rule.scope == scope && entry.rule.metric == metric && entry.rule.operation == operation &&
                (recipient.map { entry.rule.recipients?.matches($0) ?? true } ?? true)
            }
            let groups = Dictionary(grouping: eligible) { $0.rule.stackingGroup! }
            return groups.keys.sorted().compactMap { key in
                let rows = groups[key]!.sorted { $0.value == $1.value ? $0.order < $1.order : $0.value > $1.value }
                return rows.first.map { ($0, rows) }
            }
        }
        func total(_ scope: String, _ recipient: APIOwnedPlant? = nil, _ metric: String? = nil, _ operation: String = "percent") -> Decimal {
            resolve(scope, recipient, metric, operation).reduce(0) { $0 + $1.0.value }
        }
        var base: Decimal = 0, attraction: Decimal = 0, flat = total("attraction_garden", nil, nil, "flat") * 1_000_000
        for plant in plants {
            let value = try amount(plant.baseAttractionMicroUnits)
            base += value
            attraction += value * (1 + min(total("attraction_plant", plant), plantCap))
            flat += total("attraction_plant", plant, nil, "flat") * 1_000_000
        }
        attraction *= 1 + min(total("attraction_garden"), gardenCap)
        attraction += min(flat, min(flatCap * 1_000_000, flatFraction * base))
        attraction = min(attraction, base * (1 + totalCap))
        let capacity = min(Decimal(context.maximumCapacity), min(
            Decimal(context.baseCapacity) * (1 + min(total("offline_capacity"), capacityCap)) +
            min(total("offline_capacity", nil, nil, "flat") * Decimal(context.capacityFlatMultiplier), Decimal(flatCapacity)),
            Decimal(context.baseCapacity) * (1 + capacityCap)))
        let metrics = Set(regular.filter { $0.rule.scope == "activity" }.compactMap { $0.rule.metric }).sorted()
        var factors: [APISkillSummary.GrowthFactors] = []
        var rows: [String: APISkillSummary.Effect] = [:]
        func append(_ scope: String, _ plant: APIOwnedPlant? = nil, _ metric: String? = nil, entries: [Candidate]? = nil) {
            for operation in ["percent", "flat"] {
                for (winner, eligible) in resolve(scope, plant, metric, operation, entries) {
                    let rule = winner.rule, source = winner.source
                    let key = [rule.system!, scope, metric ?? "", rule.stackingGroup!, source.profile, String(source.version), rule.id].joined(separator: "/")
                    var row = rows[key] ?? APISkillSummary.Effect(skillId: rule.id, name: rule.name, description: rule.description,
                        system: rule.system!, scope: scope, metric: metric, operation: operation, magnitude: string(winner.value),
                        stackingGroup: rule.stackingGroup!, stepBand: rule.stepBand,
                        sourcePlantId: source.item ? nil : source.id, sourceItemId: source.item ? source.id : nil,
                        sourceKind: source.item ? "item" : nil,
                        eligibleSourceItemIds: eligible.filter { $0.source.item }.map { $0.source.id },
                        profileId: source.profile, profileVersion: source.version,
                        eligibleSourcePlantIds: eligible.filter { !$0.source.item }.map { $0.source.id }, recipientPlantIds: [])
                    if let plant = plant, !row.recipientPlantIds.contains(plant.id) {
                        row = row.withRecipients(row.recipientPlantIds + [plant.id])
                    }
                    rows[key] = row
                }
            }
        }
        let firstBand = try candidates("first_2000"), afterBand = try candidates("after_2000")
        for plant in plants {
            let water = total("water", plant)
            let activity = Dictionary(uniqueKeysWithValues: metrics.map { ($0, string(1 + min(total("activity", plant, $0), activityCap))) })
            factors.append(APISkillSummary.GrowthFactors(plantId: plant.id, waterFactor: string(1 + min(water, waterCap)), activityFactors: activity,
                waterCapReached: water >= waterCap, activityCapReached: Dictionary(uniqueKeysWithValues: metrics.map { ($0, total("activity", plant, $0) >= activityCap) })))
            append("attraction_plant", plant); append("water", plant)
            for metric in metrics { append("activity", plant, metric) }
            append("activity", plant, "steps", entries: firstBand.filter { $0.rule.stepBand == "first_2000" } + regular)
            append("activity", plant, "steps", entries: afterBand.filter { $0.rule.stepBand == "after_2000" } + regular)
        }
        append("attraction_garden"); append("offline_capacity"); append("welcome_duration")
        let daily = items.filter { $0.strategyRules?.dailyGrant != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        if let source = daily.first, let rules = source.strategyRules, let grant = rules.dailyGrant {
            // This is future midnight eligibility, never water granted by editing.
            guard grant.water == "2.5" else { throw unavailable }
            rows["daily_water/morning_rain"] = APISkillSummary.Effect(skillId: "morning_rain", name: "Morning Rain",
                description: "+2.5 water per eligible planted plant at account-local midnight. Duplicate harps apply once.",
                system: "growth", scope: "daily_water", metric: nil, operation: "flat", magnitude: grant.water,
                stackingGroup: "item_morning_rain", sourceItemId: source.id, sourceKind: "item", eligibleSourceItemIds: daily.map(\.id),
                profileId: rules.profileId, profileVersion: rules.profileVersion, eligibleSourcePlantIds: [], recipientPlantIds: plants.map(\.id))
        }
        let triggered = items.filter { !($0.strategyRules?.triggeredGrants ?? []).isEmpty }.sorted { $0.id.uuidString < $1.id.uuidString }
        if let source = triggered.first, let rules = source.strategyRules,
           let trigger = rules.triggeredGrants?.first {
            guard trigger.type == "daily_placed_steps_flat_water", trigger.family == "alignment_of_worlds",
                  trigger.tiers.map(\.steps) == [2000, 4000, 6000], trigger.tiers.map(\.water) == ["3", "4", "5"] else { throw unavailable }
            rows["step_tier_water/alignment_of_worlds"] = APISkillSummary.Effect(skillId: trigger.family, name: trigger.name,
                description: "2,000 / 4,000 / 6,000 daily steps while placed grant 3 / 4 / 5 flat water per planted plant. Duplicates share progress.",
                system: "growth", scope: "step_tier_water", metric: "steps", operation: "flat", magnitude: "12",
                stackingGroup: "item_alignment_of_worlds", sourceItemId: source.id, sourceKind: "item", eligibleSourceItemIds: triggered.map(\.id),
                profileId: rules.profileId, profileVersion: rules.profileVersion, eligibleSourcePlantIds: [], recipientPlantIds: plants.map(\.id))
        }
        var limits: [String] = []
        if total("attraction_garden") >= gardenCap || plants.contains(where: { total("attraction_plant", $0) >= plantCap }) ||
            (base > 0 && attraction >= base * (1 + totalCap)) || flat > min(flatCap * 1_000_000, flatFraction * base) {
            limits.append("Attraction bonuses are capped")
        }
        if total("offline_capacity") >= capacityCap || total("offline_capacity", nil, nil, "flat") * Decimal(context.capacityFlatMultiplier) > Decimal(flatCapacity) {
            limits.append("Visitor storage bonuses are capped")
        }
        if total("welcome_duration") >= Decimal(string: "0.25")! { limits.append("Welcome time bonuses are capped") }
        let summary = APISkillSummary(policyVersion: context.policyVersion, caps: caps,
            activeSkills: rows.values.sorted { $0.id < $1.id }, growthFactors: factors)
        return GardenStrategyEvaluation(totalAttractionMicroUnits: string(floor(attraction)), skillSummary: summary,
            offlineCapacity: NSDecimalNumber(decimal: floor(capacity)).intValue, context: context, limitNotices: limits,
            availableSkills: GardenAvailableSkill.collect(plants: plants, items: items))
    }
    private static var unavailable: ForestError { .invalidData("Garden effects are unavailable. Refresh your garden.") }
    private static func amount(_ value: String?) throws -> Decimal {
        guard let value = value, let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, amount >= 0 else { throw unavailable }
        return amount
    }
    private static func floor(_ value: Decimal) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, 0, .down)
        return output
    }
    static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}

extension APISkillSummary.Effect {
    func withRecipients(_ ids: [UUID]) -> Self {
        Self(skillId: skillId, name: name, description: description, system: system, scope: scope, metric: metric,
             operation: operation, magnitude: magnitude, stackingGroup: stackingGroup, stepBand: stepBand,
             sourcePlantId: sourcePlantId, sourceItemId: sourceItemId, sourceKind: sourceKind,
             eligibleSourceItemIds: eligibleSourceItemIds, profileId: profileId, profileVersion: profileVersion,
             eligibleSourcePlantIds: eligibleSourcePlantIds, recipientPlantIds: ids)
    }
}
