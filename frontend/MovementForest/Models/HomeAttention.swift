import Foundation

/// Presentation derives attention from server eligibility and confirmed receipts.
struct HomeAttention: Equatable {
    let milestones: Int
    let expeditions: Int
    let unopenedPacks: Int

    static func milestoneCount(_ rows: [APIIntroMilestone], confirmed: Set<String>) -> Int {
        Set(rows.filter { $0.eligible && !$0.claimed && !confirmed.contains($0.id) &&
            $0.supersededBy == nil && $0.unavailableReason == nil }.map(\.id)).count
    }

    static func expeditionCount(_ run: ExpeditionRun?, confirmed: UUID?) -> Int {
        // Only the current run has a reachable destination in the current UI.
        Set((run?.rewards ?? []).filter { !$0.claimed && $0.id != confirmed }.map(\.id)).count
    }

    static func packCount(_ packs: [APIOwnedPack], opened: UUID?) -> Int {
        Set(packs.filter { $0.id != opened }.map(\.id)).count
    }

    static func rewardDescription(_ count: Int) -> String {
        count == 0 ? "" : count == 1 ? "1 unclaimed reward" : "\(count) unclaimed rewards"
    }
}

struct APIHomeAttention: Decodable {
    let userId: UUID
    let milestoneCount: Int
    let expeditionCount: Int
    let unopenedPackCount: Int

    func applyingConfirmedCounts(milestones: Int?, packs: Int?) -> Self {
        Self(userId: userId, milestoneCount: milestones ?? milestoneCount, expeditionCount: expeditionCount,
             unopenedPackCount: packs.flatMap { $0 >= 0 ? $0 : nil } ?? unopenedPackCount)
    }
}

struct HomeAttentionRevision: Equatable {
    let progression: Int64
    let receipt: UUID?
}
