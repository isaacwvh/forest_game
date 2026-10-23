import XCTest
import SwiftUI
import RealityKit
import UIKit
@testable import MovementForest

@MainActor
private final class ViewportTestStatus: ObservableObject {
    @Published var expanded = false
}

@MainActor
private struct ViewportTestScreen: View {
    @ObservedObject var status: ViewportTestStatus
    let renderer: RealityGardenRenderer
    let garden: GardenSnapshot
    let catalog: BundleAssetCatalog
    let compact: Bool
    var body: some View {
        GardenViewportLayout(compact: compact) {
            GardenSceneView(renderer: renderer, garden: garden, catalog: catalog)
        } status: {
            VStack {
                Text("Your forest")
                if status.expanded {
                    ProgressView("Syncing activity")
                    Text("Confirming saved visitor request")
                    Text("The plant clearance crosses the garden boundary. Move it inside before applying.")
                    ForEach(0..<5) { _ in Text("Additional garden status and recovery information") }
                }
            }
        } controls: {
            VStack {
                Button("Plants") { }
                if status.expanded {
                    ProgressView("Loading plants")
                    Button("Apply") { }
                    Toggle("Adult preview", isOn: .constant(true))
                }
            }
        }
        .environment(\.dynamicTypeSize, .accessibility3)
    }
}

@MainActor
final class GardenViewportTests: XCTestCase {
    func testPortraitViewportDoesNotResizeForStatusOrInvalidPlacement() async throws {
        try await verifyStableViewport(compact: false)
    }
    func testCompactViewportDoesNotResizeForStatusOrInvalidPlacement() async throws {
        try await verifyStableViewport(compact: true)
    }
    private func verifyStableViewport(compact: Bool) async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        let status = ViewportTestStatus(), garden = DevelopmentScene.single.garden()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewportTestScreen(status: status,
            renderer: renderer, garden: garden, catalog: catalog, compact: compact))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; renderer.stop() }
        for _ in 0..<1500 {
            if renderer.modelLoadCount == 1 && !renderer.isLoading && renderer.view.bounds.height > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(renderer.modelLoadCount, 1)
        let bounds = renderer.view.bounds
        XCTAssertGreaterThan(bounds.height, 0); XCTAssertGreaterThan(bounds.width, 0)
        renderer.zoom(by: 0.8)
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let position = camera.position, rotation = camera.orientation.vector
        for expanded in [true, false, true] {
            status.expanded = expanded
            try await Task.sleep(nanoseconds: 150_000_000)
            window.layoutIfNeeded(); window.rootViewController?.view.layoutIfNeeded()
            XCTAssertEqual(renderer.view.bounds, bounds)
            XCTAssertEqual(camera.position, position); XCTAssertEqual(camera.orientation.vector, rotation)
            XCTAssertEqual(renderer.modelLoadCount, 1)
        }
    }
}
