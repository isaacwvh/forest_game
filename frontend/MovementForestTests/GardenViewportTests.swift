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
    func testPopupStaysAboveNavigationWithoutReservingGardenSpace() async throws {
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
        XCTAssertEqual(garden.height, viewport.height, accuracy: 1, "Selection must overlay the original full garden viewport")
        XCTAssertLessThanOrEqual(popup.maxY, viewport.maxY - overlap + 1)
    }

    func testClippedPanelContentDoesNotExcludeVisibleGardenHitTargets() async throws {
        var exclusions: [CGRect] = []
        var laidOut = false
        var sceneSize = CGSize.zero
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
        .onPreferenceChange(PopupTestBounds.self) {
            sceneSize = $0["scene"]?.size ?? .zero
            laidOut = sceneSize.height > 0
        }
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
        XCTAssertFalse(exclusions.isEmpty)
        let bounds = CGRect(origin: .zero, size: sceneSize)
        let middle = CGRect(x: 0, y: sceneSize.height * 0.55 + 1,
                            width: sceneSize.width, height: sceneSize.height * 0.05 - 2)
        for rect in exclusions {
            XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(rect))
            XCTAssertFalse(rect.intersects(middle), "Clipped overlay content must not block the clear middle of the garden")
        }
    }

    func testLeanHeaderAndCounterKeepOneAlignedRow() {
        let header = UIHostingController(rootView:
            GardenSummaryHeader(tokens: "101", attraction: "8.2", stored: "5/1500",
                                information: {}, collect: {}).environment(\.dynamicTypeSize, .large))
        let height = header.sizeThatFits(in: CGSize(width: 320, height: 1000)).height
        XCTAssertGreaterThanOrEqual(height, 44)
        XCTAssertLessThanOrEqual(height, 80)
        let counter = UIHostingController(rootView:
            TokenRewardCounter(balance: "101", reservesRewardSpace: false).environment(\.dynamicTypeSize, .large))
        let label = UIHostingController(rootView:
            QuantityLabel(metric: "tokens", text: "101").font(.subheadline).monospacedDigit()
                .environment(\.dynamicTypeSize, .large))
        let size = CGSize(width: 90, height: 1000)
        XCTAssertEqual(counter.sizeThatFits(in: size).height, label.sizeThatFits(in: size).height, accuracy: 1,
                       "Token feedback must not vertically offset the token icon inside the shared row")
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
            XCTAssertGreaterThan(bounds.height, window.bounds.height * 0.65, "Browsing must retain the original full garden viewport")
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
