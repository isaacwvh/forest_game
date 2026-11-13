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
    private func growthCopy(stage: GrowthStage = .seedling, growth: String = "250000000",
                            start: String = "100000000", next: String? = "400000000") -> APIOwnedPlant {
        let reference = APIProfileReference(id: "pinned", version: 1)
        return APIOwnedPlant(plantId: UUID(), speciesId: "oak", variantId: "standard",
            growthMicroUnits: growth, growthStage: stage, modelKey: "", thumbnailKey: "", placement: nil,
            pinnedProfiles: .init(growth: reference, behaviour: reference, attraction: reference),
            growthProgress: .init(stageStartMicroUnits: start, nextStageMicroUnits: next,
                                  maximumGrowthMicroUnits: "1000000000"))
    }
    private func growthRow(before: String, after: String, water: String,
                           beforeStage: GrowthStage, afterStage: GrowthStage,
                           plant: APIOwnedPlant? = nil) throws -> ActivityRecapRow {
        let change = APIRewardRecap.Plant(plantId: plant?.id ?? UUID(), beforeGrowthMicroUnits: before,
            afterGrowthMicroUnits: after, awardedGrowthMicroUnits: water,
            beforeStage: beforeStage, afterStage: afterStage, speciesId: "oak", variantId: "standard",
            maximumGrowthMicroUnits: "1000000000")
        let saved = recap(days: [day()], plants: [change])
        return try XCTUnwrap(ActivityRecapRow.make(recaps: [saved, saved], plants: plant.map { [$0] } ?? []).first)
    }
    private func growthCatalogue(_ profiles: [APICatalogueProfile]) -> APICatalogue {
        APICatalogue(catalogVersion: "current", isFixture: true, coordinateUnit: "garden_unit",
            gardenUnitMetres: 1, coordinateDecimalPlaces: 3, rotationDecimalPlaces: 2,
            species: [], profiles: ["growth": profiles])
    }
    func testStageAdvanceShowsOnlyWaterWithinTheNewStage() throws {
        let row = try growthRow(before: "90000000", after: "150000000", water: "60000000",
            beforeStage: .sprout, afterStage: .seedling,
            plant: growthCopy(growth: "150000000"))
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 0)
        XCTAssertEqual(progress.added, 1.0 / 6, accuracy: 0.0000001)
        XCTAssertEqual(progress.total, 1.0 / 6, accuracy: 0.0000001)
        XCTAssertTrue(row.advancesStage)
        XCTAssertEqual(row.stage, .seedling)
        XCTAssertEqual(row.water, "60000000", "The numeric gain retains water spent reaching the new stage")
    }
    func testMultipleStageAdvanceUsesFrozenFinalStageAndDeduplicatesReceipts() throws {
        let row = try growthRow(before: "90000000", after: "550000000", water: "460000000",
            beforeStage: .sprout, afterStage: .young,
            plant: growthCopy(stage: .young, growth: "800000000", start: "400000000", next: "1000000000"))
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 0)
        XCTAssertEqual(progress.added, 0.25, accuracy: 0.0000001)
        XCTAssertEqual(progress.total, 0.25, accuracy: 0.0000001)
        XCTAssertEqual(row.water, "460000000")
        XCTAssertTrue(row.advancesStage)
        XCTAssertEqual(row.stage, .young)
    }
    func testWaterWithoutStageAdvanceRetainsExistingStageProgressWithoutAnArrow() throws {
        let row = try growthRow(before: "190000000", after: "250000000", water: "60000000",
            beforeStage: .seedling, afterStage: .seedling, plant: growthCopy())
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 0.3, accuracy: 0.0000001)
        XCTAssertEqual(progress.added, 0.2, accuracy: 0.0000001)
        XCTAssertEqual(progress.total, 0.5, accuracy: 0.0000001)
        XCTAssertFalse(row.advancesStage)
    }
    func testReachingStageBoundaryShowsNewStageAndArrowWithEmptyBar() throws {
        let row = try growthRow(before: "90000000", after: "100000000", water: "10000000",
            beforeStage: .sprout, afterStage: .seedling, plant: growthCopy(growth: "100000000"))
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 0)
        XCTAssertEqual(progress.added, 0)
        XCTAssertEqual(progress.total, 0)
        XCTAssertTrue(row.advancesStage)
        XCTAssertEqual(row.stage, .seedling)
    }
    func testZeroAwardShowsCurrentStageProgressWithoutNewWaterOrArrow() throws {
        let row = try XCTUnwrap(ActivityRecapRow.make(recaps: [], plants: [growthCopy()]).first)
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(progress.existing, 0.5)
        XCTAssertEqual(progress.added, 0)
        XCTAssertEqual(progress.total, 0.5)
        XCTAssertFalse(row.advancesStage)
        XCTAssertEqual(row.stage, .seedling)
    }
    func testHistoricalStageUsesExactPinnedProfileWhenLiveCopyIsAlreadyAdult() throws {
        let plant = growthCopy(stage: .adult, growth: "1000000000", start: "1000000000", next: nil)
        let row = try growthRow(before: "190000000", after: "240000000", water: "50000000",
            beforeStage: .seedling, afterStage: .seedling, plant: plant)
        let pinned = APICatalogueProfile(id: "pinned", version: 1,
            thresholdsMicroUnits: ["sprout": "0", "seedling": "40000000", "young": "840000000", "adult": "1000000000"],
            maximumGrowthMicroUnits: "1000000000")
        let current = APICatalogueProfile(id: "pinned", version: 2,
            thresholdsMicroUnits: ["sprout": "0", "seedling": "100000000", "young": "400000000", "adult": "1000000000"],
            maximumGrowthMicroUnits: "1000000000")
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row, catalogue: growthCatalogue([current, pinned])))
        XCTAssertEqual(progress.existing, 0.1875, accuracy: 0.0000001)
        XCTAssertEqual(progress.added, 0.0625, accuracy: 0.0000001)
        XCTAssertEqual(progress.total, 0.25, accuracy: 0.0000001)
        XCTAssertEqual(row.stage, .seedling, "The live adult must not replace the receipt's stage")
        XCTAssertNil(RecapGrowthDisplay(row: row, catalogue: growthCatalogue([current])),
                     "A different profile version must not replace missing pinned thresholds")
        XCTAssertNil(RecapGrowthDisplay(row: row))
    }
    func testMissingHistoricalThresholdsDoNotFallBackToLifetimeProgress() throws {
        let change = APIRewardRecap.Plant(plantId: UUID(), beforeGrowthMicroUnits: "90000000",
            afterGrowthMicroUnits: "550000000", awardedGrowthMicroUnits: "460000000",
            beforeStage: .sprout, afterStage: .young, speciesId: "oak", variantId: "standard",
            maximumGrowthMicroUnits: "1000000000")
        let saved = recap(days: [day()], plants: [change])
        let row = try XCTUnwrap(ActivityRecapRow.make(recaps: [saved, saved], plants: []).first)
        XCTAssertNil(RecapGrowthDisplay(row: row))
        XCTAssertEqual(row.water, "460000000")
        XCTAssertTrue(row.advancesStage)
        XCTAssertEqual(row.afterStage, .young)
        XCTAssertEqual(row.speciesID, "oak", "Historical identities can still show exact bundled artwork")
    }
    func testAdultAndUnknownGrowthDoNotInventNewStageWater() throws {
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
    func testReachingAdulthoodKeepsStageAdvanceWithoutInventingAnotherStage() throws {
        let row = try growthRow(before: "960000000", after: "1000000000", water: "40000000",
            beforeStage: .young, afterStage: .adult,
            plant: growthCopy(stage: .adult, growth: "1000000000", start: "1000000000", next: nil))
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertEqual(row.stage, .adult)
        XCTAssertTrue(row.advancesStage)
        XCTAssertEqual(progress.total, 1)
        XCTAssertEqual(progress.added, 0)
    }
    func testTinyStageWaterStaysPositiveAndMalformedBoundsStayUnavailable() throws {
        let row = try growthRow(before: "100000000", after: "100000001", water: "1",
            beforeStage: .seedling, afterStage: .seedling, plant: growthCopy(growth: "100000001"))
        let progress = try XCTUnwrap(RecapGrowthDisplay(row: row))
        XCTAssertGreaterThan(progress.added, 0)
        for plant in [growthCopy(start: "invalid"), growthCopy(start: "400000000"),
                      growthCopy(next: "100000000"), growthCopy(next: nil)] {
            let invalid = try growthRow(before: "190000000", after: "250000000", water: "60000000",
                beforeStage: .seedling, afterStage: .seedling, plant: plant)
            XCTAssertNil(RecapGrowthDisplay(row: invalid))
        }
    }
    func testInconsistentSavedGrowthCannotProduceAMisleadingStageBar() throws {
        let tooMuchWater = try growthRow(before: "0", after: "250000000", water: "300000000",
            beforeStage: .seedling, afterStage: .seedling, plant: growthCopy())
        XCTAssertNil(RecapGrowthDisplay(row: tooMuchWater))
        let wrongStage = try growthRow(before: "190000000", after: "400000000", water: "210000000",
            beforeStage: .seedling, afterStage: .seedling, plant: growthCopy())
        XCTAssertNil(RecapGrowthDisplay(row: wrongStage), "The next boundary cannot appear as a full old-stage bar")
        let notMature = try growthRow(before: "900000000", after: "950000000", water: "50000000",
            beforeStage: .young, afterStage: .adult,
            plant: growthCopy(stage: .adult, growth: "1000000000", start: "1000000000", next: nil))
        XCTAssertNil(RecapGrowthDisplay(row: notMature))
        let plant = growthCopy(stage: .adult, growth: "1000000000", start: "1000000000", next: nil)
        let historic = try growthRow(before: "190000000", after: "250000000", water: "60000000",
            beforeStage: .seedling, afterStage: .seedling, plant: plant)
        let wrongMaximum = APICatalogueProfile(id: "pinned", version: 1,
            thresholdsMicroUnits: ["seedling": "100000000", "young": "400000000"],
            maximumGrowthMicroUnits: "2000000000")
        XCTAssertNil(RecapGrowthDisplay(row: historic, catalogue: growthCatalogue([wrongMaximum])))
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
