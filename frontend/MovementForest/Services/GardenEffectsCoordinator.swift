import Foundation
import Combine

struct GardenEffectTarget: Equatable, Identifiable {
    var id: UUID { plantID }
    let plantID: UUID
    var water: Bool
    var before: GrowthStage
    var after: GrowthStage
    var advancesStage: Bool { after.number > before.number }
}

/// Cosmetic state only. Neither consuming an effect nor interrupting it settles rewards.
/// The disk record contains receipt identities only, scoped by server and account.
@MainActor
final class GardenEffectsCoordinator {
    let changes = PassthroughSubject<Void, Never>()
    private(set) var holdingRecap = false
    private(set) var targets: [UUID: GardenEffectTarget] = [:]
    private(set) var minimumStateVersion: Int64 = 0
    private let disk: AccountDiskStore?
    private let server: String
    private let user: UUID
    private var consumed: Set<UUID> = []
    private var presentedStages: [String: Int] = [:]
    private var historyReadable = true
    private var activityRequests: [UUID] = []
    private struct History: Codable {
        let recaps: [UUID]
        let stages: [String: Int]
    }

    init(server: String, user: UUID, disk: AccountDiskStore? = AccountDiskStore()) {
        self.server = server; self.user = user; self.disk = disk
        do {
            if let history = try disk?.load(History.self, kind: "growth-effects", server: server, user: user) {
                consumed = Set(history.recaps); presentedStages = history.stages
            }
        }
        catch { historyReadable = false } // Prefer quiet feedback to replaying unverifiable history.
    }

    func beginRecap() {
        targets = [:]; holdingRecap = true
        changes.send()
    }

    func recordActivity(requestID: UUID, before: APIGarden?, after: APIGarden) {
        guard historyReadable, !activityRequests.contains(requestID), let before = before,
              before.gardenId == after.gardenId, after.stateVersion > before.stateVersion else { return }
        activityRequests.append(requestID)
        if activityRequests.count > 256 { activityRequests.removeFirst() }
        minimumStateVersion = max(minimumStateVersion, after.stateVersion)
        let old = Dictionary(before.plants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for plant in after.plants {
            guard let previous = old[plant.id], plant.placement != nil, previous.placement != nil,
                  previous.speciesId == plant.speciesId, previous.variantId == plant.variantId,
                  plant.growthStage.number > previous.growthStage.number,
                  let award = ExactAmount.integer(plant.growthMicroUnits),
                  let earlier = ExactAmount.integer(previous.growthMicroUnits), award > earlier else { continue }
            merge(.init(plantID: plant.id, water: false, before: previous.growthStage, after: plant.growthStage))
        }
        changes.send()
    }

    /// Called only for a loaded, displayed recap after its sheet has dismissed.
    /// Persist consumption before playback; failed acknowledgements cannot replay it.
    func finishRecap(_ recaps: [APIRewardRecap], garden: APIGarden?, allowPresentation: Bool) {
        holdingRecap = false
        let unique = Dictionary(recaps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = unique.values.filter { !consumed.contains($0.id) }
        var next = consumed
        next.formUnion(unique.keys)
        var saved = historyReadable
        if saved && next != consumed {
            do {
                try saveHistory(recaps: next, stages: presentedStages)
                consumed = next
            } catch { saved = false }
        }
        targets = [:] // The frozen recap, rather than a later sync, owns this ceremony.
        if allowPresentation, saved, let garden = garden {
            minimumStateVersion = garden.stateVersion
            let placed = Set(garden.plants.filter { $0.placement != nil }.map(\.id))
            for row in ActivityRecapRow.make(recaps: Array(fresh), plants: []) {
                guard placed.contains(row.id), let amount = ExactAmount.integer(row.water), amount > 0,
                      let before = row.beforeStage, let after = row.afterStage else { continue }
                merge(.init(plantID: row.id, water: true, before: before, after: after))
            }
        }
        changes.send()
    }

    func takeTargets(for garden: GardenSnapshot) -> [GardenEffectTarget] {
        guard !holdingRecap, Int64(garden.stateVersion) >= minimumStateVersion else { return [] }
        let plants = Dictionary(garden.plants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eligible = targets.values.filter {
            guard let plant = plants[$0.id] else { return false }
            return plant.growthStage.number >= $0.after.number
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        targets = [:]
        guard !eligible.isEmpty else { return [] }
        var stages = presentedStages
        let result = eligible.map { target -> GardenEffectTarget in
            var result = target
            if (stages[target.id.uuidString] ?? 0) >= target.after.number { result.before = result.after }
            if result.advancesStage { stages[target.id.uuidString] = target.after.number }
            return result
        }
        if stages != presentedStages {
            do { try saveHistory(recaps: consumed, stages: stages); presentedStages = stages }
            catch { return result.filter(\.water).map { .init(plantID: $0.id, water: true, before: $0.after, after: $0.after) } }
        }
        return result.filter { $0.water || $0.advancesStage }
    }

    func cancel() {
        holdingRecap = false; targets = [:]
        changes.send()
    }

    private func merge(_ target: GardenEffectTarget) {
        guard let old = targets[target.id] else { targets[target.id] = target; return }
        targets[target.id] = .init(plantID: target.id, water: old.water || target.water,
            before: old.before.number < target.before.number ? old.before : target.before,
            after: old.after.number > target.after.number ? old.after : target.after)
    }

    private func saveHistory(recaps: Set<UUID>, stages: [String: Int]) throws {
        try disk?.save(History(recaps: recaps.sorted { $0.uuidString < $1.uuidString }, stages: stages),
                       kind: "growth-effects", server: server, user: user)
    }
}

struct ConfirmedTokenReward: Equatable, Identifiable {
    let id: UUID
    let amount: String
}
