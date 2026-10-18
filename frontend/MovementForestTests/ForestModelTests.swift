import XCTest
import simd
@testable import MovementForest

final class ForestModelTests: XCTestCase {
    func testAllDeliveredStageVariantsResolve() throws {
        let catalog = try BundleAssetCatalog()
        XCTAssertEqual(catalog.species.map(\.speciesId), ["oak", "moonwillow"])
        XCTAssertEqual(catalog.species.reduce(0) { $0 + $1.assets.count }, 20)
        for manifest in catalog.species {
            for stage in GrowthStage.allCases {
                for variant in manifest.variantIds {
                    let asset = try catalog.resolve(speciesId: manifest.speciesId, version: manifest.assetVersion, stage: stage, variant: variant)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: asset.modelURL.path))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: asset.thumbnailURL.path))
                    XCTAssertEqual(asset.asset.stage, stage)
                }
            }
        }
        XCTAssertThrowsError(try catalog.resolve(speciesId: "moonwillow", version: "1.0.0", stage: .adult, variant: "default"))
    }

    func testGroundMappingPreservesFractionalCoordinatesAndUnits() {
        XCTAssertEqual(GardenCoordinates.world(x: 3.2, y: 4.6, unitMetres: 1), SIMD3<Float>(3.2, 0, 4.6))
        XCTAssertEqual(GardenCoordinates.world(x: 3.2, y: 4.6, unitMetres: 2), SIMD3<Float>(6.4, 0, 9.2))
        let hit = GardenCoordinates.groundIntersection(origin: [3.2, 10, 4.6], direction: [0, -1, 0], width: 10, depth: 10, unitMetres: 1)
        XCTAssertEqual(hit?.x ?? -1, 3.2, accuracy: 0.0001)
        XCTAssertEqual(hit?.y ?? -1, 4.6, accuracy: 0.0001)
        XCTAssertNil(GardenCoordinates.groundIntersection(origin: [3, 10, 4], direction: [1, 0, 0], width: 10, depth: 10, unitMetres: 1))
        XCTAssertNil(GardenCoordinates.groundIntersection(origin: [11, 10, 4], direction: [0, -1, 0], width: 10, depth: 10, unitMetres: 1))
        XCTAssertNil(GardenCoordinates.groundIntersection(origin: [3, 10, 4], direction: [0, 1, 0], width: 10, depth: 10, unitMetres: 1))
    }

    func testAxisCorrectionIsAppliedOnlyToZUpImport() {
        let authored = SIMD3<Float>(5, 2.7, 4.8)
        XCTAssertTrue(AssetOrientation.needsZUpCorrection(imported: authored, authored: authored))
        XCTAssertFalse(AssetOrientation.needsZUpCorrection(imported: [5, 4.8, 2.7], authored: authored))
    }

    func testStageChangePreservesIdentityAndPlacement() {
        var plant = DevelopmentScene.single.garden().plants[0]
        let original = plant
        for stage in GrowthStage.allCases {
            plant.growthStage = stage
            XCTAssertEqual(plant.id, original.id)
            XCTAssertEqual(plant.x, original.x)
            XCTAssertEqual(plant.y, original.y)
            XCTAssertEqual(plant.rotationDegrees, original.rotationDegrees)
            XCTAssertEqual(plant.assetVersion, original.assetVersion)
        }
    }

    func testDevelopmentScenesAreStableAndValid() throws {
        let catalog = try BundleAssetCatalog()
        for scene in DevelopmentScene.allCases {
            let garden = try scene.garden().validated()
            XCTAssertEqual(garden, scene.garden())
            XCTAssertEqual(garden.plants.count, scene == .single ? 1 : 15)
            for plant in garden.plants { _ = try catalog.resolve(plant) }
        }
        var invalid = DevelopmentScene.single.garden()
        invalid.plants[0].x = .nan
        XCTAssertThrowsError(try invalid.validated())
        invalid = DevelopmentScene.single.garden()
        invalid.plants.append(invalid.plants[0])
        XCTAssertThrowsError(try invalid.validated())
    }

    func testDayBucketsUseCalendarDaysAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T19:00:00Z"))
        let days = ActivityCalendar.days(endingAt: now, count: 3, timeZone: zone)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[1].duration, 23 * 60 * 60)
        XCTAssertEqual(days[2].end, now)
        XCTAssertEqual(days[0].end, days[1].start)
        XCTAssertEqual(days[1].end, days[2].start)
    }

    @MainActor
    func testBundledGardenIsSampleAndHasNoDuplicatePlants() async throws {
        let garden = try await SampleGardenRepository().loadGarden()
        XCTAssertTrue(garden.isSample)
        XCTAssertEqual(garden.plants.count, 15)
        XCTAssertEqual(Set(garden.plants.map(\.id)).count, 15)
    }
}
