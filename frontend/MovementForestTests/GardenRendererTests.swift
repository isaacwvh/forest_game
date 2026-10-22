import XCTest
import Foundation
import RealityKit
@testable import MovementForest

@MainActor
final class GardenRendererTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Renderer did not reach the expected state within 15 seconds")
        throw URLError(.timedOut)
    }

    func testPreviewCancelAndConfirmedMoveReuseTheLoadedEntity() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        defer { renderer.stop() }
        var garden = DevelopmentScene.single.garden()
        let id = garden.plants[0].id
        renderer.display(garden, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        let original = try XCTUnwrap(renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
        let x = original.position.x
        var candidate = garden.plants[0]
        candidate.x += 0.125
        renderer.updatePreview(EditorRenderPreview(plant: candidate, radius: 0.9, valid: true, adult: false, movable: true), catalog: catalog)
        XCTAssertEqual(original.position.x, x + 0.125, accuracy: 0.0001)
        XCTAssertEqual(renderer.modelLoadCount, 1)
        renderer.updatePreview(nil, catalog: catalog)
        XCTAssertEqual(original.position.x, x, accuracy: 0.0001)
        garden.plants[0] = candidate
        renderer.display(garden, catalog: catalog)
        try await waitUntil { original.position.x == Float(candidate.x * garden.gardenUnitMetres) }
        let moved = renderer.view.scene.anchors.first?.findEntity(named: id.uuidString)
        XCTAssertTrue(original === moved)
        XCTAssertEqual(renderer.modelLoadCount, 1)
    }

    func testConfirmedStageChangePreservesTransformAndSameStageRefreshReusesModel() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        defer { renderer.stop() }
        var garden = DevelopmentScene.single.garden()
        garden.plants[0].x = 3.201; garden.plants[0].y = 4.609; garden.plants[0].rotationDegrees = 35.12
        let id = garden.plants[0].id
        renderer.display(garden, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        let original = try XCTUnwrap(renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
        let position = original.position, orientation = original.orientation
        garden.plants[0].growthStage = garden.plants[0].growthStage == .adult ? .young : .adult
        renderer.display(garden, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 2 && !renderer.isLoading }
        let changed = try XCTUnwrap(renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
        XCTAssertEqual(changed.position, position)
        XCTAssertEqual(changed.orientation.vector, orientation.vector)
        let refreshed = GardenSnapshot(gardenId: garden.gardenId, title: garden.title, isSample: garden.isSample,
                                       width: garden.width, depth: garden.depth, gardenUnitMetres: garden.gardenUnitMetres,
                                       catalogVersion: garden.catalogVersion, layoutVersion: garden.layoutVersion,
                                       stateVersion: garden.stateVersion + 1, plants: garden.plants)
        renderer.display(refreshed, catalog: catalog)
        try await waitUntil { !renderer.isLoading }
        XCTAssertEqual(renderer.modelLoadCount, 2)
        XCTAssertTrue(changed === renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
    }
}
