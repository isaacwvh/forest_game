import XCTest
import Foundation
import RealityKit
import Combine
import UIKit
@testable import MovementForest

@MainActor
final class GardenRendererTests: XCTestCase {
    func testRecapPreloadsStageAndInterruptedRevealPreservesAnchorAndCamera() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        let effects = GardenEffectsCoordinator(server: "test", user: UUID(), disk: nil)
        renderer.setGrowthEffects(effects)
        defer { renderer.stop() }
        var first = DevelopmentScene.single.garden()
        first.plants[0].growthStage = .sprout
        renderer.display(first, catalog: catalog); renderer.setActive(true)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        let id = first.plants[0].id
        let anchor = try XCTUnwrap(renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let position = anchor.position, rotation = anchor.orientation.vector, cameraPosition = camera.position
        effects.beginRecap(); renderer.setActive(false)
        var plants = first.plants; plants[0].growthStage = .young
        let after = GardenSnapshot(gardenId: first.gardenId, title: first.title, isSample: first.isSample,
            width: first.width, depth: first.depth, gardenUnitMetres: first.gardenUnitMetres, catalogVersion: first.catalogVersion,
            layoutVersion: first.layoutVersion, stateVersion: first.stateVersion + 1, plants: plants)
        renderer.display(after, catalog: catalog)
        try await waitUntil { renderer.preparedGrowthCount == 1 && !renderer.isLoading }
        XCTAssertEqual(renderer.modelLoadCount, 1, "The sheet must not hide the stage swap")
        XCTAssertTrue(anchor === renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
        // Background/cancellation installs already-confirmed state quietly.
        effects.cancel()
        try await waitUntil { renderer.preparedGrowthCount == 0 && renderer.modelLoadCount == 2 }
        XCTAssertTrue(anchor === renderer.view.scene.anchors.first?.findEntity(named: id.uuidString))
        XCTAssertEqual(anchor.position, position); XCTAssertEqual(anchor.orientation.vector, rotation)
        XCTAssertEqual(camera.position, cameraPosition)
        renderer.setActive(true)
        XCTAssertEqual(renderer.modelLoadCount, 2)
    }

    func testVisitorAssetRequestHandlesImmediateValueAndEmptyCompletion() async throws {
        let expected = Entity()
        let result = try await VisitorAssetLoadRequest().run { Just(expected).setFailureType(to: Error.self).eraseToAnyPublisher() }
        XCTAssertTrue(result === expected)
        do {
            _ = try await VisitorAssetLoadRequest().run { Empty<Entity, Error>().eraseToAnyPublisher() }
            XCTFail("Empty completion must fail rather than leave artwork loading")
        } catch VisitorAssetLoadError.empty { }
    }

    func testCancellingVisitorAssetRequestCancelsSubscriptionAndIgnoresLateValue() async throws {
        let subject = PassthroughSubject<Entity, Error>()
        var subscribed = false, cancelled = false
        let publisher = subject.handleEvents(receiveSubscription: { _ in subscribed = true }, receiveCancel: { cancelled = true })
        let request = VisitorAssetLoadRequest()
        let task = Task { try await request.run { publisher.eraseToAnyPublisher() } }
        try await waitUntil { subscribed }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled artwork request returned a model")
        } catch is CancellationError { }
        XCTAssertTrue(cancelled)
        subject.send(Entity()); subject.send(completion: .finished)
        await Task.yield()
    }

    func testViewDetachPreservesSceneAndCameraButTerminalStopReleasesScene() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        defer { renderer.stop() }
        let garden = DevelopmentScene.single.garden()
        renderer.display(garden, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        renderer.zoom(by: 0.8)
        let plant = try XCTUnwrap(renderer.view.scene.anchors.first?.findEntity(named: garden.plants[0].id.uuidString))
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let position = camera.position
        renderer.onSelect = { _ in }; renderer.onGroundDrag = { _, _ in }
        renderer.setActive(true); renderer.detachView()
        XCTAssertNil(renderer.onSelect); XCTAssertNil(renderer.onGroundDrag)
        XCTAssertTrue(renderer.view.isHidden)
        renderer.display(garden, catalog: catalog); renderer.setActive(true)
        XCTAssertFalse(renderer.view.isHidden)
        XCTAssertEqual(camera.position, position)
        XCTAssertEqual(renderer.modelLoadCount, 1)
        XCTAssertTrue(plant === renderer.view.scene.anchors.first?.findEntity(named: garden.plants[0].id.uuidString))
        renderer.stop(); renderer.stop()
        renderer.display(garden, catalog: catalog); renderer.setActive(true)
        XCTAssertTrue(renderer.view.isHidden)
        XCTAssertTrue(renderer.view.scene.anchors.isEmpty)
        XCTAssertTrue(renderer.view.gestureRecognizers?.isEmpty ?? true)
    }

    func testAccessibleCameraActionsPreserveModelsAndExplicitResetRestoresPerspective() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        defer { renderer.stop() }
        renderer.display(DevelopmentScene.single.garden(), catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        renderer.setActive(true)
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let position = camera.position, rotation = camera.orientation.vector
        for action in GardenCameraAction.allCases where action != .reset {
            XCTAssertTrue(renderer.performCameraAction(action))
            XCTAssertEqual(renderer.modelLoadCount, 1)
        }
        XCTAssertTrue(renderer.performCameraAction(.reset))
        XCTAssertEqual(camera.position, position); XCTAssertEqual(camera.orientation.vector, rotation)
        renderer.detachView()
        XCTAssertFalse(renderer.performCameraAction(.zoomIn))
        XCTAssertEqual(camera.position, position)
    }

    func testRetiredGardenSessionReleasesRendererAndCallbacks() async throws {
        var session: GardenRenderSession? = GardenRenderSession()
        weak var renderer = session?.renderer
        session?.renderer.onSelect = { _ in }
        session = nil
        try await waitUntil { renderer == nil }
        XCTAssertNil(renderer)
    }

    func testButterflyLibraryCoalescesImportsAndReturnsIndependentClones() async throws {
        let library = VisitorModelLibrary()
        let first = Task { try await library.load() }
        let second = Task { try await library.load() }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(library.loadCount, 1)
        XCTAssertFalse(a === b)
        a.position.x = 42
        XCTAssertNotEqual(a.position.x, b.position.x)
        let third = try await library.load()
        XCTAssertEqual(library.loadCount, 1)
        XCTAssertNotEqual(third.position.x, a.position.x)
    }

    func testVersionRefreshPauseAndAssetRetryPreserveCamera() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        defer { renderer.stop() }
        let garden = DevelopmentScene.single.garden()
        renderer.display(garden, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        renderer.zoom(by: 0.8)
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let position = camera.position, rotation = camera.orientation.vector
        var loading: [Bool] = []
        let subscription = renderer.$isLoading.dropFirst().sink { loading.append($0) }
        defer { subscription.cancel() }
        let refreshed = GardenSnapshot(gardenId: garden.gardenId, title: garden.title, isSample: garden.isSample,
            width: garden.width, depth: garden.depth, gardenUnitMetres: garden.gardenUnitMetres,
            catalogVersion: garden.catalogVersion, layoutVersion: garden.layoutVersion,
            stateVersion: garden.stateVersion + 1, plants: garden.plants)
        renderer.display(refreshed, catalog: catalog)
        renderer.setActive(false); renderer.setActive(true)
        renderer.display(refreshed, catalog: catalog)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(loading.isEmpty, "A metadata-only sync flashed asset loading")
        XCTAssertEqual(camera.position, position); XCTAssertEqual(camera.orientation.vector, rotation)
        XCTAssertEqual(renderer.modelLoadCount, 1)
        renderer.retry(refreshed, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 2 && !renderer.isLoading }
        XCTAssertEqual(camera.position, position); XCTAssertEqual(camera.orientation.vector, rotation)
    }

    func testInvalidOrCancelledPlantDragCannotBecomeCameraOrbit() async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        defer { renderer.stop() }
        let garden = DevelopmentScene.single.garden()
        renderer.display(garden, catalog: catalog)
        try await waitUntil { renderer.modelLoadCount == 1 && !renderer.isLoading }
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let position = camera.position, rotation = camera.orientation.vector
        var preview = EditorRenderPreview(plant: garden.plants[0], radius: 0.9, valid: true, adult: false, movable: true)
        renderer.updatePreview(preview, catalog: catalog)
        renderer.handleSingleFingerPan(state: .began, translation: .zero, location: .zero)
        preview.valid = false; preview.plant.x = -1
        renderer.updatePreview(preview, catalog: catalog)
        renderer.handleSingleFingerPan(state: .changed, translation: CGPoint(x: 50, y: 20), location: .zero)
        renderer.updatePreview(nil, catalog: catalog)
        renderer.handleSingleFingerPan(state: .changed, translation: CGPoint(x: 50, y: 20), location: .zero)
        renderer.handleSingleFingerPan(state: .ended, translation: CGPoint(x: 50, y: 20), location: .zero)
        XCTAssertEqual(camera.position, position); XCTAssertEqual(camera.orientation.vector, rotation)
        renderer.handleSingleFingerPan(state: .began, translation: .zero, location: .zero)
        renderer.handleSingleFingerPan(state: .changed, translation: CGPoint(x: 50, y: 20), location: .zero)
        renderer.handleSingleFingerPan(state: .ended, translation: .zero, location: .zero)
        XCTAssertNotEqual(camera.position, position, "A subsequent camera gesture must still work")
    }

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
