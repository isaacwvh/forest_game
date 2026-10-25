import Foundation
import Combine

/// Entry eligibility belongs to the app session, never to a sync notification.
struct AppEntryGate {
    private(set) var account: UUID?
    private var server: String?
    private var consumed = false
    mutating func enter(account: UUID, server: String = "") -> Bool {
        if self.account != account || self.server != server {
            self.account = account; self.server = server; consumed = false
        }
        guard !consumed else { return false }
        consumed = true
        return true
    }
    mutating func background() { consumed = false }
    mutating func signOut() { account = nil; server = nil; consumed = false }
}

struct ActivityRecapRow: Identifiable {
    let id: UUID
    let plant: APIOwnedPlant?
    let water: String
    let skillWater: String
    let beforeStage: GrowthStage?
    let afterStage: GrowthStage?

    static func make(recaps: [APIRewardRecap], plants: [APIOwnedPlant]) -> [Self] {
        let copies = Dictionary(plants.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let unique = Dictionary(recaps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = Dictionary(grouping: unique.values.flatMap { $0.payload.plants }, by: \.plantId)
        return Set(copies.keys).union(changes.keys).map { id in
            let credits = (changes[id] ?? []).sorted {
                (ExactAmount.integer($0.beforeGrowthMicroUnits) ?? 0) < (ExactAmount.integer($1.beforeGrowthMicroUnits) ?? 0)
            }
            func sum(_ values: [String]) -> String {
                NSDecimalNumber(decimal: values.reduce(Decimal(0)) { $0 + (ExactAmount.integer($1) ?? 0) }).stringValue
            }
            return Self(id: id, plant: copies[id], water: sum(credits.map(\.awardedGrowthMicroUnits)),
                        skillWater: sum(credits.compactMap(\.skillBonusGrowthMicroUnits)),
                        beforeStage: credits.first?.beforeStage, afterStage: credits.last?.afterStage)
        }.sorted {
            let left = ExactAmount.integer($0.water) ?? 0, right = ExactAmount.integer($1.water) ?? 0
            if (left > 0) != (right > 0) { return left > 0 }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

@MainActor
final class AppEntryRecapCoordinator: ObservableObject {
    @Published var showing = false
    @Published private(set) var loading = false
    @Published private(set) var rows: [ActivityRecapRow] = []
    @Published private(set) var status = ""
    @Published private(set) var activeSkills: [APISkillSummary.Effect] = []
    private(set) var receiptIDs = Set<UUID>()
    private var gate = AppEntryGate()
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private weak var sync: ActivitySyncCoordinator?

    func begin(sync: ActivitySyncCoordinator, editor: GardenEditorStore) {
        guard gate.enter(account: editor.profile.userId, server: editor.service.serverID) else { return }
        task?.cancel()
        let token = UUID(); generation = token
        self.sync = sync
        rows = []; receiptIDs = []; activeSkills = []
        loading = true; showing = true; status = "Checking activity…"
        task = Task { [weak self] in
            let confirmed = await sync.synchronize()
            guard let self = self, !Task.isCancelled, self.generation == token,
                  self.showing, editor.isActive else { return }
            let recaps = sync.recaps
            var copies = (editor.confirmed?.plants ?? []) + editor.inventory
            var missing = Set(recaps.flatMap { $0.payload.plants.map(\.plantId) }).subtracting(copies.map(\.id))
            var cursor = editor.nextCursor
            var seen = Set<UUID>()
            // Only read more storage pages when a historical credit needs its identity.
            while !missing.isEmpty, let next = cursor, seen.insert(next).inserted {
                guard let page = try? await editor.service.inventory(after: next) else { break }
                guard !Task.isCancelled, self.generation == token, self.showing, editor.isActive else { return }
                copies += page.plants
                missing.subtract(page.plants.map(\.id)); cursor = page.nextCursor
            }
            self.receiptIDs = Set(recaps.map(\.id))
            let affected = Set(recaps.flatMap { $0.payload.plants.map(\.plantId) })
            self.rows = ActivityRecapRow.make(recaps: recaps, plants: copies.filter { $0.placement != nil || affected.contains($0.id) })
            self.activeSkills = editor.confirmed?.skillSummary?.activeSkills ?? []
            self.status = confirmed ? (recaps.isEmpty ? "No new confirmed growth." : "Your growth is already saved.") :
                "Activity could not be fully refreshed. Showing available confirmed progress. You can retry in Activity."
            self.loading = false
        }
    }

    func dismissed() {
        guard !showing else { return }
        task?.cancel(); generation = UUID(); showing = false
        let ids = receiptIDs
        receiptIDs = []
        // Keep acknowledgement independent of any later batch or account attachment.
        if !ids.isEmpty, let sync = sync { Task { await sync.dismissRecaps(ids: ids) } }
    }

    func background() {
        task?.cancel(); generation = UUID(); receiptIDs = []
        showing = false; gate.background()
    }

    func signOut() {
        background(); gate.signOut(); sync = nil; rows = []; activeSkills = []
    }
}
