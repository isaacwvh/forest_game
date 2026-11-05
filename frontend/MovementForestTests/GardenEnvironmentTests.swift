import Combine
import RealityKit
import UIKit
import XCTest
@testable import MovementForest

@MainActor
final class GardenEnvironmentTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Garden scenery did not finish loading")
        throw CocoaError(.fileReadUnknown)
    }

    private func findSurface(_ node: Entity) -> Entity? {
        if node.name.contains("Island_FlatPlantingSurface") { return node }
        for child in node.children { if let surface = findSurface(child) { return surface } }
        return nil
    }

    private func assertNoCollisions(_ node: Entity, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(node.components[CollisionComponent.self], file: file, line: line)
        for child in node.children { assertNoCollisions(child, file: file, line: line) }
    }

    func testBundledIslandPreservesGroundAndRectangularPlantingFootprint() async throws {
        let environment = GardenEnvironment()
        defer { environment.stop() }
        let anchor = AnchorEntity(world: .zero)
        let island = environment.makeIsland(width: 14, depth: 8)
        anchor.addChild(island)
        try await waitUntil { island.findEntity(named: "garden-island-visual") != nil }
        let surface = try XCTUnwrap(findSurface(island))
        let bounds = surface.visualBounds(relativeTo: anchor)
        XCTAssertEqual(bounds.min.y, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds.max.y, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds.min.x, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds.max.x, 14, accuracy: 0.0001)
        XCTAssertEqual(bounds.min.z, 0, accuracy: 0.0001)
        XCTAssertEqual(bounds.max.z, 8, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(island.visualBounds(relativeTo: anchor).max.y, 0.0001)
        assertNoCollisions(island)
        XCTAssertNil(island.findEntity(named: "garden-island-fallback"))
    }

    func testLateImportInstallsOnlyOnCurrentIslandAndReusesTemplate() async throws {
        let subject = PassthroughSubject<Entity, Error>()
        var imports = 0
        let environment = GardenEnvironment(importIsland: { _ in
            imports += 1
            return subject.eraseToAnyPublisher()
        })
        defer { environment.stop() }
        let first = environment.makeIsland(width: 10, depth: 10)
        let current = environment.makeIsland(width: 14, depth: 8)
        let template = Entity()
        let surface = ModelEntity(mesh: .generateBox(size: [10, 1, 10]))
        surface.position.y = -0.5
        surface.generateCollisionShapes(recursive: false)
        template.addChild(surface)
        subject.send(template)
        subject.send(completion: .finished)
        try await waitUntil { current.findEntity(named: "garden-island-visual") != nil }
        XCTAssertNil(first.findEntity(named: "garden-island-visual"))
        XCTAssertEqual(current.position, SIMD3<Float>(7, 0, 4))
        XCTAssertEqual(current.visualBounds(relativeTo: nil).max.y, 0, accuracy: 0.0001)
        assertNoCollisions(current)
        let next = environment.makeIsland(width: 6, depth: 6)
        XCTAssertNotNil(next.findEntity(named: "garden-island-visual"))
        XCTAssertNil(next.findEntity(named: "garden-island-fallback"))
        XCTAssertEqual(imports, 1)
        assertNoCollisions(next)
    }

    func testStopCancelsPendingArtworkAndKeepsLateResultsOutOfScene() async throws {
        let subject = PassthroughSubject<Entity, Error>()
        var cancelled = false
        let environment = GardenEnvironment(importIsland: { _ in
            subject.handleEvents(receiveCancel: { cancelled = true }).eraseToAnyPublisher()
        })
        let island = environment.makeIsland(width: 10, depth: 10)
        environment.stop()
        subject.send(Entity())
        subject.send(completion: .finished)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(cancelled)
        XCTAssertNil(island.findEntity(named: "garden-island-visual"))
        XCTAssertEqual(island.visualBounds(relativeTo: nil).max.y, 0, accuracy: 0.0001)
        assertNoCollisions(island)
    }

    func testStaticBackdropCoversViewportWithoutStretchingImage() throws {
        for visible in [SIMD2<Float>(100, 220), SIMD2<Float>(130, 200), SIMD2<Float>(220, 100)] {
            let size = try XCTUnwrap(GardenEnvironment.backdropSize(visibleSize: visible, imageAspect: 2 / 3))
            XCTAssertGreaterThanOrEqual(size.x + 0.0001, visible.x)
            XCTAssertGreaterThanOrEqual(size.y + 0.0001, visible.y)
            XCTAssertEqual(size.x / size.y, Float(2) / 3, accuracy: 0.0001)
        }
        XCTAssertNil(GardenEnvironment.backdropSize(visibleSize: .zero, imageAspect: 2 / 3))
        XCTAssertNil(GardenEnvironment.backdropSize(visibleSize: [.nan, 200], imageAspect: 2 / 3))
    }
}
