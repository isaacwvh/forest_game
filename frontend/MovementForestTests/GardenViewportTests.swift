import XCTest
import SwiftUI
import RealityKit
import UIKit
@testable import MovementForest

@MainActor
private final class ViewportTestStatus: ObservableObject {
    @Published var expanded = false
}

private struct PopupTestBounds: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private struct ViewportTestScreen: View {
    @ObservedObject var status: ViewportTestStatus
    let renderer: RealityGardenRenderer
    let garden: GardenSnapshot
    let catalog: BundleAssetCatalog
    let compact: Bool
    let editing: Bool
    var body: some View {
        GardenViewportLayout(compact: compact, editing: editing) {
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
    func testDockedPopupStaysOutsideTheGardenAndAboveNavigation() async throws {
        var frames: [String: CGRect] = [:]
        let overlap: CGFloat = 64
        let content = GeometryReader { geometry in
            GardenViewportLayout(compact: false) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GeometryReader { scene in
                        Color.clear.preference(key: PopupTestBounds.self, value: ["scene": scene.frame(in: .global)])
                    })
            } status: {
                EmptyView()
            } controls: {
                GardenSelectionPopup(name: "Oak", variant: "Standard", stage: "Young plant", close: {}, details: {})
                    .background(GeometryReader { popup in
                        Color.clear.preference(key: PopupTestBounds.self, value: ["popup": popup.frame(in: .global)])
                    })
            }
            .environment(\.gardenBottomNavigationTop, geometry.frame(in: .global).maxY - overlap)
            .background(Color.clear.preference(key: PopupTestBounds.self,
                value: ["viewport": geometry.frame(in: .global)]))
        }
        .environment(\.dynamicTypeSize, .large)
        .onPreferenceChange(PopupTestBounds.self) { frames = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if (frames["popup"]?.height ?? 0) > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let popup = try XCTUnwrap(frames["popup"]), viewport = try XCTUnwrap(frames["viewport"])
        let garden = try XCTUnwrap(frames["scene"])
        XCTAssertGreaterThan(popup.height, 44)
        XCTAssertGreaterThan(garden.height, 0)
        XCTAssertGreaterThanOrEqual(popup.minY, garden.maxY - 1)
        XCTAssertLessThanOrEqual(popup.maxY, viewport.maxY - overlap + 1)
    }

    func testReservedRegionsNeverCoverTheGardenAcrossSizesAndTextSettings() {
        for size in [CGSize(width: 320, height: 480), CGSize(width: 390, height: 844),
                     CGSize(width: 430, height: 932), CGSize(width: 700, height: 320),
                     CGSize(width: 320, height: 260)] {
            for editing in [false, true] {
                for compact in [false, true] {
                    for accessibility in [false, true] {
                        let visibleHeight = size.height - (editing ? 0 : 64)
                        let regions = GardenViewportRegions(size: size, visibleHeight: visibleHeight,
                            editing: editing, compact: compact, accessibility: accessibility)
                        XCTAssertGreaterThan(regions.scene.width, 0)
                        XCTAssertGreaterThan(regions.scene.height, 0)
                        XCTAssertFalse(regions.scene.intersects(regions.status))
                        XCTAssertFalse(regions.scene.intersects(regions.controls))
                        for rect in [regions.scene, regions.status, regions.controls] {
                            XCTAssertGreaterThanOrEqual(rect.minX, 0)
                            XCTAssertGreaterThanOrEqual(rect.minY, 0)
                            XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.001)
                            XCTAssertLessThanOrEqual(rect.maxY, visibleHeight + 0.001)
                        }
                    }
                }
            }
        }
    }

    func testClippedPanelContentDoesNotExcludeVisibleGardenHitTargets() async throws {
        var exclusions: [CGRect] = []
        var laidOut = false
        let content = GardenViewportLayout(compact: false) {
            Color.clear.background(GeometryReader { scene in
                Color.clear.preference(key: PopupTestBounds.self, value: ["scene": scene.frame(in: .global)])
            })
        } status: {
            Color.clear.frame(height: 1000).gardenOverlayTarget()
        } controls: {
            Color.clear.frame(height: 1000).gardenOverlayTarget()
        }
        .onPreferenceChange(GardenOverlayFrames.self) { exclusions = $0 }
        .onPreferenceChange(PopupTestBounds.self) { laidOut = ($0["scene"]?.height ?? 0) > 0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if laidOut { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(laidOut)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(exclusions.isEmpty, "Offscreen panel content must not block native visitor accessibility")
    }

    func testPortraitViewportDoesNotResizeForStatusOrInvalidPlacement() async throws {
        try await verifyStableViewport(compact: false)
    }
    func testCompactViewportDoesNotResizeForStatusOrInvalidPlacement() async throws {
        try await verifyStableViewport(compact: true)
    }
    func testPortraitEditingPanelsRemainStable() async throws {
        try await verifyStableViewport(compact: false, editing: true)
    }
    func testCompactEditingPanelsRemainStable() async throws {
        try await verifyStableViewport(compact: true, editing: true)
    }
    private func verifyStableViewport(compact: Bool, editing: Bool = false) async throws {
        let renderer = RealityGardenRenderer(), catalog = try BundleAssetCatalog()
        let status = ViewportTestStatus(), garden = DevelopmentScene.single.garden()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ViewportTestScreen(status: status,
            renderer: renderer, garden: garden, catalog: catalog, compact: compact, editing: editing))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; renderer.stop() }
        for _ in 0..<1500 {
            if renderer.modelLoadCount == 1 && !renderer.isLoading && renderer.view.bounds.height > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(renderer.modelLoadCount, 1)
        let bounds = renderer.view.bounds
        XCTAssertGreaterThan(bounds.height, 0); XCTAssertGreaterThan(bounds.width, 0)
        if !editing {
            XCTAssertGreaterThan(bounds.height, window.bounds.height * 0.35, "The garden must stay usable above its dedicated panels")
        }
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
