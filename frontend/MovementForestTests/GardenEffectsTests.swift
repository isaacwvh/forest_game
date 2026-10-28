import XCTest
import Foundation
import RealityKit
import UIKit
@testable import MovementForest

@MainActor
final class GardenEffectsTests: XCTestCase {
    private let gardenID = UUID()

    private func plant(_ id: UUID, stage: GrowthStage = .sprout, growth: String = "0", placed: Bool = true) -> APIOwnedPlant {
        .init(plantId: id, speciesId: "oak", variantId: "standard", growthMicroUnits: growth, growthStage: stage,
              modelKey: "", thumbnailKey: "", placement: placed ? .init(gardenId: gardenID, x: 3, y: 4, rotationDegrees: 25) : nil)
    }

    private func garden(_ plants: [APIOwnedPlant], version: Int64 = 1) -> APIGarden {
        .init(gardenId: gardenID, width: 10, depth: 10, coordinateUnit: "garden_unit", gardenUnitMetres: 1,
              catalogVersion: "test", layoutVersion: 1, stateVersion: version, plants: plants)
    }

    private func rendered(_ plants: [APIOwnedPlant], version: Int = 1) -> GardenSnapshot {
        .init(gardenId: gardenID, title: "Test", isSample: false, width: 10, depth: 10, gardenUnitMetres: 1,
              catalogVersion: "test", layoutVersion: 1, stateVersion: version,
              plants: plants.filter { $0.placement != nil }.map {
                .init(id: $0.id, speciesId: $0.speciesId, variantId: $0.variantId, assetVersion: "1.0.0",
                      growthStage: $0.growthStage, x: 3, y: 4, rotationDegrees: 25)
              })
    }

    private func recap(_ id: UUID = UUID(), plant: UUID, award: String = "1",
                       before: GrowthStage = .sprout, after: GrowthStage = .sprout) -> APIRewardRecap {
        .init(recapId: id, createdAt: Date(), payload: .init(kind: "activity_growth", creditIds: [],
            plants: [.init(plantId: plant, beforeGrowthMicroUnits: "0", afterGrowthMicroUnits: award,
                           awardedGrowthMicroUnits: award, beforeStage: before, afterStage: after)],
            activityDays: [], resourceDeltas: [:]))
    }

    func testWateringUsesPositiveExactAwardsAndCurrentPlacedCopyIdentity() throws {
        let positive = UUID(), unchanged = UUID(), capped = UUID(), stored = UUID(), duplicateSpecies = UUID()
        let copies = [plant(positive), plant(unchanged), plant(capped, stage: .adult), plant(stored, placed: false), plant(duplicateSpecies)]
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil)
        let tiny = recap(plant: positive) // One micro-unit must count even when rounded UI shows zero.
        effects.beginRecap()
        effects.finishRecap([tiny, tiny, recap(plant: unchanged, award: "0"), recap(plant: capped, award: "0", before: .adult, after: .adult),
                            recap(plant: stored), recap(plant: duplicateSpecies, award: "0")],
                           garden: garden(copies), allowPresentation: true)
        let targets = effects.takeTargets(for: rendered(copies))
        XCTAssertEqual(targets.map(\.id), [positive])
        XCTAssertTrue(try XCTUnwrap(targets.first).water)
        XCTAssertFalse(try XCTUnwrap(targets.first).advancesStage)
        XCTAssertTrue(effects.takeTargets(for: rendered(copies)).isEmpty)
    }

    func testNoGrowthUnavailableInvalidOrSuppressedRecapNeverWaters() {
        let id = UUID(), copies = [plant(UUID())]
        for award in ["0", "-1", "unavailable", "0.5"] {
            let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil)
            effects.beginRecap()
            effects.finishRecap([recap(plant: id, award: award)], garden: garden([plant(id)]), allowPresentation: true)
            XCTAssertTrue(effects.targets.isEmpty, award)
        }
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil)
        effects.beginRecap()
        effects.finishRecap([], garden: garden(copies), allowPresentation: true)
        XCTAssertTrue(effects.targets.isEmpty)
        effects.beginRecap()
        effects.finishRecap([recap(plant: copies[0].id)], garden: garden(copies), allowPresentation: false)
        XCTAssertTrue(effects.targets.isEmpty)
    }

    func testFrozenBatchDeduplicatesOldReceiptsButStillWatersNewCredits() {
        let id = UUID(), copies = [plant(id)], old = recap(plant: id)
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil)
        effects.beginRecap(); effects.finishRecap([old], garden: garden(copies), allowPresentation: true)
        XCTAssertEqual(effects.takeTargets(for: rendered(copies)).count, 1)
        effects.beginRecap(); effects.finishRecap([old], garden: garden(copies), allowPresentation: true)
        XCTAssertTrue(effects.takeTargets(for: rendered(copies)).isEmpty)
        effects.beginRecap(); effects.finishRecap([old, recap(plant: id)], garden: garden(copies), allowPresentation: true)
        XCTAssertEqual(effects.takeTargets(for: rendered(copies)).count, 1)
    }

    func testPresentationHistorySurvivesRelaunchAndIsolatesAccountAndServer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AccountDiskStore(directory: directory), user = UUID(), id = UUID(), copies = [plant(id)], receipt = recap(plant: id)
        let first = GardenEffectsCoordinator(server: "a", user: user, disk: disk)
        first.beginRecap(); first.finishRecap([receipt], garden: garden(copies), allowPresentation: true)
        XCTAssertEqual(first.takeTargets(for: rendered(copies)).count, 1)
        for (server, account, expected) in [("a", user, 0), ("b", user, 1), ("a", UUID(), 1)] {
            let next = GardenEffectsCoordinator(server: server, user: account, disk: disk)
            next.beginRecap(); next.finishRecap([receipt], garden: garden(copies), allowPresentation: true)
            XCTAssertEqual(next.takeTargets(for: rendered(copies)).count, expected)
        }
    }

    func testUnwritableOrUnreadableHistorySuppressesEffectsWithoutAffectingGrowth() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID(), copies = [plant(id)]
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: AccountDiskStore(directory: file))
        effects.beginRecap(); effects.finishRecap([recap(plant: id)], garden: garden(copies), allowPresentation: true)
        XCTAssertTrue(effects.targets.isEmpty)
        XCTAssertEqual(copies.first?.growthMicroUnits, "0")
    }

    func testStageProvenanceHoldMultiStageAndReplayAreIndependentOfWatering() throws {
        let id = UUID(), before = [plant(id)], after = [plant(id, stage: .young, growth: "3000000")]
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil), request = UUID()
        effects.beginRecap()
        effects.recordActivity(requestID: request, before: garden(before), after: garden(after, version: 2))
        XCTAssertTrue(effects.takeTargets(for: rendered(after, version: 2)).isEmpty)
        effects.finishRecap([recap(plant: id, award: "3000000", after: .young)], garden: garden(after, version: 2), allowPresentation: true)
        XCTAssertTrue(effects.takeTargets(for: rendered(before)).isEmpty, "Never animate before the confirmed scene catches up")
        let target = try XCTUnwrap(effects.takeTargets(for: rendered(after, version: 2)).first)
        XCTAssertEqual(target.before, .sprout); XCTAssertEqual(target.after, .young)
        XCTAssertTrue(target.water); XCTAssertTrue(target.advancesStage)
        effects.recordActivity(requestID: request, before: garden(before), after: garden(after, version: 2))
        XCTAssertTrue(effects.targets.isEmpty)
        effects.cancel()
        XCTAssertFalse(effects.holdingRecap)
    }

    func testPreviouslyShownStageDoesNotCelebrateAgainInALaterWateringRecap() throws {
        let id = UUID(), before = [plant(id)], after = [plant(id, stage: .young, growth: "3000000")]
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil)
        effects.recordActivity(requestID: UUID(), before: garden(before), after: garden(after, version: 2))
        let first = try XCTUnwrap(effects.takeTargets(for: rendered(after, version: 2)).first)
        XCTAssertTrue(first.advancesStage); XCTAssertFalse(first.water)
        effects.beginRecap()
        effects.finishRecap([recap(plant: id, award: "3000000", after: .young)], garden: garden(after, version: 2), allowPresentation: true)
        let later = try XCTUnwrap(effects.takeTargets(for: rendered(after, version: 2)).first)
        XCTAssertTrue(later.water); XCTAssertFalse(later.advancesStage)
    }

    func testSharedEffectsBoundEmittersAndRestoreAuthoredMaterialsOnCancel() throws {
        let effects = SharedGardenEffects(), root = Entity()
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .brown)
        let source = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
        root.addChild(source)
        let position = source.position
        for _ in 0..<15 {
            effects.enqueue(.init(plantID: UUID(), water: true, before: .sprout, after: .sprout),
                            source: source, parent: root, reducedMotion: false, replace: { source })
        }
        XCTAssertEqual(effects.activeCount, SharedGardenEffects.maximumConcurrent)
        XCTAssertEqual(effects.queuedCount, 15 - SharedGardenEffects.maximumConcurrent)
        effects.tick(0.5)
        effects.cancel()
        XCTAssertEqual(effects.activeCount, 0); XCTAssertEqual(effects.queuedCount, 0)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(source.position, position)
        let restored = try XCTUnwrap(source.model?.materials.first as? PhysicallyBasedMaterial)
        XCTAssertEqual(restored.baseColor.tint, material.baseColor.tint)
        XCTAssertEqual(restored.emissiveIntensity, material.emissiveIntensity)
    }

    func testReducedMotionUsesNoParticlesAndSwapsExactlyOnce() {
        let effects = SharedGardenEffects(), root = Entity(), source = ModelEntity(mesh: .generateBox(size: 1), materials: [SimpleMaterial(color: .green, isMetallic: false)])
        root.addChild(source)
        var swaps = 0
        effects.enqueue(.init(plantID: UUID(), water: true, before: .sprout, after: .adult), source: source,
                        parent: root, reducedMotion: true, replace: { swaps += 1; return source })
        XCTAssertEqual(root.children.last?.children.count, 0)
        effects.tick(0.2); effects.tick(0.2); effects.tick(0.2)
        XCTAssertEqual(swaps, 1); XCTAssertEqual(effects.activeCount, 0)
        XCTAssertEqual(root.children.count, 1)
    }
}
