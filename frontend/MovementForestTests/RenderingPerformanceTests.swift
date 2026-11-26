import XCTest
import UIKit
import Combine
@testable import MovementForest

@MainActor
final class RenderingPerformanceTests: XCTestCase {
    func testSharedRenderingPolicy() throws {
        XCTAssertEqual(try RenderPolicyChecks.run(), 17)
    }

    func testNativeScaleRemainsStableAcrossMountsAndPickingUsesPoints() {
        let renderer = RealityGardenRenderer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let controller = UIViewController()
        window.rootViewController = controller
        renderer.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { renderer.stop(); window.isHidden = true }
        for _ in 0..<3 {
            controller.view.addSubview(renderer.view)
            XCTAssertEqual(renderer.view.contentScaleFactor, window.screen.scale * 0.85, accuracy: 0.0001)
            XCTAssertEqual(renderer.view.bounds.size, window.bounds.size)
            renderer.view.removeFromSuperview()
        }
    }

    func testPresentationImagesReuseDecodeAndEvictOnMemoryPressure() throws {
        let path = "oak/v1/ui/oak-sprout-standard.png"
        let first = try XCTUnwrap(PresentationAssets.image(path, maximumPixels: 128))
        let again = try XCTUnwrap(PresentationAssets.image(path, maximumPixels: 128))
        XCTAssertTrue(first === again)
        let smaller = try XCTUnwrap(PresentationAssets.image(path, maximumPixels: 64))
        XCTAssertLessThanOrEqual(max(smaller.size.width, smaller.size.height), 64)
        XCTAssertFalse(first === smaller)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let reloaded = try XCTUnwrap(PresentationAssets.image(path, maximumPixels: 128))
        XCTAssertFalse(first === reloaded)
        XCTAssertNil(PresentationAssets.image(path, maximumPixels: 0))
    }

    #if DEBUG
    func testRootObservesNavigationButNotSelectionAndPreviewUpdates() async throws {
        let connection = GardenConnection()
        await connection.installPresentationFixture(assets: try BundleAssetCatalog())
        let editor = try XCTUnwrap(connection.editor)
        for _ in 0..<8 { await Task.yield() }
        let observer = RootPresentationObserver(connection: connection)
        var changes = 0
        let subscription = observer.objectWillChange.sink { changes += 1 }
        editor.selectedID = UUID()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(changes, 0)
        editor.editing = true
        for _ in 0..<8 { await Task.yield() }
        XCTAssertGreaterThan(changes, 0)
        let beforePreview = changes
        editor.selectedID = UUID(); editor.adultPreview = true
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(changes, beforePreview)
        withExtendedLifetime(subscription) {}
        connection.disconnect()
    }
    #endif
}
