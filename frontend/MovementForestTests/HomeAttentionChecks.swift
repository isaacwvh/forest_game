import Foundation
#if canImport(MovementForest)
@testable import MovementForest
#endif

/// Shared by XCTest and the portable Swift runner; executes the shipped policy.
enum HomeAttentionChecks {
    private struct Failure: Error { let reason: String }
    private struct Milestones: Decodable {
        struct Summary: Decodable { let milestones: [APIIntroMilestone]? }
        let earned: Summary
    }
    private struct Expeditions: Decodable {
        let initial: ExpeditionRun
        let earned: ExpeditionRun
        let restored: ExpeditionRun
    }
    private struct Collection: Decodable {
        struct Page: Decodable { let packs: [APIOwnedPack] }
        let packs: Page
    }

    static func run(fixtures: URL) throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
            guard condition() else { throw Failure(reason: reason) }
            count += 1
        }
        let decoder = ActivityWire.decoder()
        let milestones = try decoder.decode(Milestones.self, from: Data(contentsOf: fixtures.appendingPathComponent("milestones-contract.json")))
        let rows = milestones.earned.milestones ?? []
        try check(HomeAttention.milestoneCount(rows, confirmed: []) == 10, "Real earned fixture has ten unclaimed rewards")
        let earnedIDs = Set(rows.filter(\.eligible).map(\.id))
        try check(HomeAttention.milestoneCount(rows, confirmed: earnedIDs) == 0, "Confirmed receipts suppress stale server claims")
        try check(HomeAttention.milestoneCount([], confirmed: []) == 0, "Unknown milestones never invent attention")
        let eligible = APIIntroMilestone(milestoneId: "ready", title: "Ready", description: "Test", rewardTokens: "1", eligible: true, claimed: false)
        let claimed = APIIntroMilestone(milestoneId: "claimed", title: "Claimed", description: "Test", rewardTokens: "1", eligible: true, claimed: true)
        let locked = APIIntroMilestone(milestoneId: "locked", title: "Locked", description: "Test", rewardTokens: "1", eligible: false, claimed: false)
        var superseded = eligible; superseded.supersededBy = "replacement"
        var unavailable = eligible; unavailable.unavailableReason = "Unsupported reward"
        try check(HomeAttention.milestoneCount([eligible, claimed, locked, superseded, unavailable], confirmed: []) == 1,
            "Claimed, locked, superseded and unsupported rows are excluded")
        try check(HomeAttention.milestoneCount([eligible], confirmed: [eligible.id]) == 0, "A receipt clears attention without a summary refresh")
        try check(HomeAttention.milestoneCount([eligible, eligible], confirmed: []) == 1, "Repeated milestone records count once")

        let expedition = try decoder.decode(Expeditions.self, from: Data(contentsOf: fixtures.appendingPathComponent("expeditions-contract.json")))
        try check(HomeAttention.expeditionCount(nil, confirmed: nil) == 0, "Missing expedition has no rewards")
        try check(HomeAttention.expeditionCount(expedition.initial, confirmed: nil) == 0, "Incomplete expedition has no reward badge")
        try check(HomeAttention.expeditionCount(expedition.earned, confirmed: nil) == 11, "Nine pieces and two item rewards are counted")
        try check(HomeAttention.expeditionCount(expedition.restored, confirmed: nil) == 0, "All confirmed expedition claims clear attention")
        let entitlement = expedition.earned.rewards[0].id
        try check(HomeAttention.expeditionCount(expedition.earned, confirmed: entitlement) == 10, "A retained receipt suppresses stale expedition state")
        var duplicated = expedition.earned
        duplicated.rewards.append(duplicated.rewards[0])
        try check(HomeAttention.expeditionCount(duplicated, confirmed: nil) == 11, "An entitlement is never counted twice")
        let confirmed = expedition.earned.confirmingClaims([entitlement])
        try check(HomeAttention.expeditionCount(confirmed, confirmed: entitlement) == 10, "Receipt and refreshed snapshot cannot double-subtract")

        let collection = try decoder.decode(Collection.self, from: Data(contentsOf: fixtures.appendingPathComponent("collection-contract.json")))
        let packs = collection.packs.packs
        try check(HomeAttention.packCount(packs, opened: nil) == 1, "Owned unopened pack is actionable")
        try check(HomeAttention.packCount(packs, opened: packs[0].id) == 0, "Confirmed opening suppresses stale pack page")
        try check(HomeAttention.packCount(packs + packs, opened: nil) == 1, "Repeated pages do not duplicate attention")
        try check(HomeAttention.packCount([], opened: nil) == 0, "Missing packs never invent attention")
        try check(HomeAttention.rewardDescription(0).isEmpty, "Zero rewards stays quiet")
        try check(HomeAttention.rewardDescription(1) == "1 unclaimed reward", "Accessible singular reason")
        try check(HomeAttention.rewardDescription(2) == "2 unclaimed rewards", "Accessible plural reason")
        return count
    }
}
