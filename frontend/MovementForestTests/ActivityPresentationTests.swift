import XCTest
import Foundation
@testable import MovementForest

final class ActivityPresentationTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Singapore")!
    private func day(_ steps: Int64 = 1200, metrics: [String: APIActivityMetricReceipt]? = nil) -> APIActivityDayResult {
        APIActivityDayResult(gameDate: "2026-10-31", available: true, baselineEstablished: false,
            newlyEligibleSteps: steps, waterSteps: steps, creditedSteps: steps, ruleVersion: "test",
            activityCreditId: UUID(), metrics: metrics)
    }
    private func recap(days: [APIActivityDayResult], plants: [APIRewardRecap.Plant] = [],
                       version: Int? = 1, workouts: [APIWorkoutReceipt]? = []) -> APIRewardRecap {
        APIRewardRecap(recapId: UUID(), createdAt: Date(), payload: .init(kind: "activity_growth",
            creditIds: [], plants: plants, activityDays: days, resourceDeltas: [:],
            activitySummaryVersion: version, workouts: workouts))
    }
    func testPreviousDayNewStepsAreIndependentOfTodaysZero() {
        let now = ISO8601DateFormatter().date(from: "2026-11-01T00:01:00+08:00")!
        let start = ActivityCalendar.calendar(timeZone: zone).startOfDay(for: now)
        let report = ActivityReport(observedAt: now, timeZoneIdentifier: zone.identifier,
            days: [ActivityDay(start: start, end: now, steps: 0)], workouts: [],
            stepsIssue: nil, workoutsIssue: nil, isFixture: true)
        let today = ActivityDailyTotals(report: report, timeZone: zone, now: now)
        let summary = ActivityRecapSummary(recaps: [recap(days: [day()])])
        XCTAssertEqual(today.amounts[.steps], 0)
        XCTAssertEqual(summary.amounts[.steps], 1200)
        XCTAssertNil(today.amounts[.energy], "Missing Health quantities must not become zero")
        let tomorrow = now.addingTimeInterval(86400)
        XCTAssertNil(ActivityDailyTotals(report: report, timeZone: zone, now: tomorrow).amounts[.steps])
    }
    func testAllMetricReceiptsAndWorkoutsDeduplicateWithoutUsingTodaysHealthTotals() {
        let workoutID = UUID()
        let accepted = APIWorkoutReceipt(workoutId: workoutID, status: "accepted", newlyEligibleMinutes: "11/2")
        let old = APIWorkoutReceipt(workoutId: workoutID, status: "already_processed")
        let receipt = recap(days: [day(metrics: [
            "walking_running_distance_km": .init(available: true, newlyEligible: "6/5"),
            "active_energy_kcal": .init(available: true, newlyEligible: "30"),
            "flights_climbed": .init(available: true, newlyEligible: "2"),
            "workout_minutes.running": .init(available: true, newlyEligible: "11/2"),
        ])], workouts: [old, accepted, accepted])
        let summary = ActivityRecapSummary(recaps: [receipt, receipt])
        XCTAssertEqual(summary.amounts[.steps], 1200)
        XCTAssertEqual(summary.amounts[.distance], Decimal(string: "1.2"))
        XCTAssertEqual(summary.amounts[.energy], 30)
        XCTAssertEqual(summary.amounts[.flights], 2)
        XCTAssertEqual(summary.amounts[.workouts], 1)
        XCTAssertEqual(summary.amounts[.workoutMinutes], Decimal(string: "5.5"))
    }
    func testLegacyMissingDetailsStayUnavailableEvenInAMixedBatch() {
        let old = recap(days: [day()], version: nil, workouts: nil)
        let new = recap(days: [day(metrics: ["active_energy_kcal": .init(available: true, newlyEligible: "30")])])
        let summary = ActivityRecapSummary(recaps: [old, new])
        XCTAssertEqual(summary.amounts[.steps], 2400)
        XCTAssertNil(summary.amounts[.energy])
        XCTAssertNil(summary.amounts[.workouts])
        XCTAssertNil(summary.amounts[.workoutMinutes])
    }
    func testOrangeGainUsesFrozenCumulativeGrowthAcrossAStageChange() throws {
        let change = APIRewardRecap.Plant(plantId: UUID(), beforeGrowthMicroUnits: "90000000",
            afterGrowthMicroUnits: "350000000", awardedGrowthMicroUnits: "260000000",
            beforeStage: .sprout, afterStage: .young, speciesId: "oak", variantId: "standard",
            maximumGrowthMicroUnits: "1000000000")
        let saved = recap(days: [day()], plants: [change])
        let row = try XCTUnwrap(ActivityRecapRow.make(recaps: [saved, saved], plants: []).first)
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 0.09, accuracy: 0.0000001)
        XCTAssertEqual(progress.added, 0.26, accuracy: 0.0000001)
        XCTAssertEqual(progress.total, 0.35, accuracy: 0.0000001)
        XCTAssertEqual(row.water, "260000000")
        XCTAssertEqual(row.afterStage, .young)
        XCTAssertEqual(row.speciesID, "oak", "Historical identities can still show exact bundled artwork")
    }
    func testAdultAndUnknownGrowthDoNotInventAnOrangeGain() throws {
        let plant = APIOwnedPlant(plantId: UUID(), speciesId: "oak", variantId: "standard",
            growthMicroUnits: "1000000000", growthStage: .adult, modelKey: "", thumbnailKey: "", placement: nil,
            growthProgress: .init(stageStartMicroUnits: "1000000000", nextStageMicroUnits: nil,
                                  maximumGrowthMicroUnits: "1000000000"))
        let row = try XCTUnwrap(ActivityRecapRow.make(recaps: [], plants: [plant]).first)
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 1)
        XCTAssertEqual(progress.added, 0)
        var unknown = plant; unknown.growthProgress = nil
        XCTAssertNil(RecapGrowthDisplay(row: try XCTUnwrap(ActivityRecapRow.make(recaps: [], plants: [unknown]).first)))
    }
    func testStepOnlyReadsAndUnreadableWorkoutsNeverPretendToBeZeroWorkouts() {
        let now = Date(), start = ActivityCalendar.calendar(timeZone: zone).startOfDay(for: now)
        var report = ActivityReport(observedAt: now, timeZoneIdentifier: zone.identifier,
            days: [ActivityDay(start: start, end: now, steps: 100)], workouts: [],
            stepsIssue: nil, workoutsIssue: nil, isFixture: true, includesOptionalActivity: false)
        XCTAssertEqual(ActivityDailyTotals(report: report, timeZone: zone, now: now).amounts[.steps], 100)
        XCTAssertNil(ActivityDailyTotals(report: report, timeZone: zone, now: now).amounts[.workouts])
        report.includesOptionalActivity = true
        XCTAssertEqual(ActivityDailyTotals(report: report, timeZone: zone, now: now).amounts[.workouts], 0)
        let unavailable = ActivityReport(observedAt: now, timeZoneIdentifier: zone.identifier,
            days: report.days, workouts: [], stepsIssue: nil, workoutsIssue: "Read failed", isFixture: true)
        XCTAssertNil(ActivityDailyTotals(report: unavailable, timeZone: zone, now: now).amounts[.workouts])
    }
    func testRationalQuantitiesRejectMalformedValuesAndPreserveTinyPositiveAmounts() {
        XCTAssertEqual(ActivityDisplayAmount.decimal("3/2"), Decimal(string: "1.5"))
        for raw in ["1/0", "-1", "1/2/3", "1x", ""] { XCTAssertNil(ActivityDisplayAmount.decimal(raw)) }
        XCTAssertTrue(ActivityDisplayAmount.text(Decimal(string: "0.001")).hasPrefix("<"))
        XCTAssertEqual(ActivityDisplayAmount.text(nil), "Unavailable")
    }
    func testTodaysWorkoutDurationClipsAtMidnightAndCountsEachIdentityOnce() {
        let now = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00+08:00")!
        let start = ActivityCalendar.calendar(timeZone: zone).startOfDay(for: now)
        let workout = WorkoutObservation(id: UUID(), activityType: 37, title: "Running", isRunning: true,
            start: now.addingTimeInterval(-3600), end: now, durationSeconds: 3600, distanceMetres: nil,
            sourceName: "Test", sourceBundleIdentifier: "example.test", wasUserEntered: false)
        let report = ActivityReport(observedAt: now, timeZoneIdentifier: zone.identifier,
            days: [ActivityDay(start: start, end: now, steps: 0)], workouts: [workout, workout],
            stepsIssue: nil, workoutsIssue: nil, isFixture: true)
        let totals = ActivityDailyTotals(report: report, timeZone: zone, now: now)
        XCTAssertEqual(totals.amounts[.workouts], 1)
        XCTAssertEqual(totals.amounts[.workoutMinutes], 30)
    }
}
