import XCTest

final class ForestUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFourEntryNavigationStartsOnGardenAndSampleOwnershipIsTruthful() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]; app.launch()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 15))
        let labels = ["My plants", "Garden", "Edit", "Activity"]
        let buttons = labels.map { app.buttons["navigation." + $0] }
        for button in buttons { XCTAssertTrue(button.exists) }
        for index in 1..<buttons.count { XCTAssertLessThan(buttons[index - 1].frame.midX, buttons[index].frame.midX) }
        XCTAssertFalse(app.buttons["navigation.Edit"].isEnabled)
        app.buttons["navigation.My plants"].tap()
        XCTAssertTrue(app.staticTexts["Your plants belong here"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.place"].exists)
        app.buttons["navigation.Garden"].tap()
        XCTAssertTrue(app.buttons["garden.info"].exists)
    }

    func testGardenHeaderRetainsInfoAndDisablesUnavailableCollectionWithoutPermanentControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["visitors.claim"].exists)
        XCTAssertFalse(app.buttons["visitors.claim"].isEnabled)
        XCTAssertFalse(app.buttons["garden.plants"].exists)
        XCTAssertFalse(app.buttons["Zoom in"].exists); XCTAssertFalse(app.buttons["Zoom out"].exists)
        XCTAssertFalse(app.buttons["Reset garden view"].exists)
        XCTAssertFalse(app.buttons["visitors.welcome"].exists)
        app.buttons["garden.info"].tap()
        XCTAssertTrue(app.navigationBars["Garden information"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Garden controls"].exists)
    }

    func testOwnedBrowsingIsReadOnlyAndStorageOpensDetailsBeforePlace() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        let edit = app.buttons["navigation.Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: edit); waitForExpectations(timeout: 10)
        app.buttons["navigation.My plants"].tap()
        XCTAssertTrue(app.staticTexts["Planted"].exists); XCTAssertTrue(app.staticTexts["Stored"].exists)
        let owned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.stored.")).firstMatch
        XCTAssertTrue(owned.waitForExistence(timeout: 5)); owned.tap()
        XCTAssertTrue(app.staticTexts["Growth stage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.place"].exists); XCTAssertFalse(app.buttons["editor.move"].exists)
        app.buttons["navigation.Edit"].tap()
        XCTAssertTrue(app.buttons["editor.done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation.My plants"].exists); XCTAssertFalse(app.buttons["collection.menu"].exists)
        app.buttons["editor.storage"].tap()
        let stored = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.copy.")).firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 5)); stored.tap()
        XCTAssertTrue(app.buttons["editor.place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.apply"].exists)
        app.buttons["editor.place"].tap()
        XCTAssertTrue(app.buttons["editor.cancel"].waitForExistence(timeout: 5)); app.buttons["editor.cancel"].tap()
        app.buttons["editor.storage"].tap(); stored.tap(); app.buttons["editor.place"].tap()
        app.buttons["editor.apply"].tap()
        XCTAssertTrue(app.buttons["editor.done"].exists); app.buttons["editor.done"].tap()
        XCTAssertTrue(app.buttons["navigation.My plants"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved."].exists)
        app.buttons["navigation.My plants"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.planted.")).firstMatch.waitForExistence(timeout: 5))
    }

    func testDeveloperDiagnosticsAreReachableThroughSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]; app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15)); app.buttons["Settings"].tap()
        app.buttons["settings.developer"].tap(); app.buttons["developer.diagnostics.link"].tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
    }

    func testBrowsingRetainsTheMountedGardenCameraAndModelImports() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]; app.launch()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 15))
        func inspect() throws -> [String] {
            app.buttons["Settings"].tap(); app.buttons["settings.developer"].tap(); app.buttons["developer.diagnostics.link"].tap()
            let loading = app.descendants(matching: .any).matching(identifier: "diagnostic.renderer.loading").firstMatch
            XCTAssertTrue(loading.waitForExistence(timeout: 5))
            expectation(for: NSPredicate(format: "value == %@", "false"), evaluatedWith: loading)
            waitForExpectations(timeout: 30)
            let values = try ["identity", "imports", "camera"].map { key -> String in
                let row = app.descendants(matching: .any).matching(identifier: "diagnostic.renderer." + key).firstMatch
                return try XCTUnwrap(row.value as? String)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap() // Diagnostics → Developer tools
            app.navigationBars.buttons.element(boundBy: 0).tap() // Developer tools → Settings
            app.navigationBars.buttons["Done"].firstMatch.tap()
            return values
        }
        _ = try inspect() // Wait for initial artwork before moving the camera.
        let scene = app.descendants(matching: .any).matching(identifier: "garden.scene").firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 15))
        let start = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65))
        let end = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
        let initial = try inspect()
        for destination in ["My plants", "Activity", "Garden"] { app.buttons["navigation." + destination].tap() }
        XCTAssertEqual(try inspect(), initial)
    }

    func testBackgroundExitsFocusedEditingAndCancelsThePreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        let edit = app.buttons["navigation.Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: edit)
        waitForExpectations(timeout: 10); edit.tap()
        app.buttons["editor.storage"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.copy.")).firstMatch.tap()
        app.buttons["editor.place"].tap()
        XCTAssertTrue(app.buttons["editor.cancel"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["navigation.Garden"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["editor.done"].exists); XCTAssertFalse(app.buttons["editor.cancel"].exists)
        app.buttons["navigation.My plants"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.stored.")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.planted.")).firstMatch.exists)
    }

    func testPackOpeningWaitsForBothTapsForEveryRarity() {
        let app = XCUIApplication()
        for rarity in ["common", "rare", "epic", "legendary"] {
            app.launchArguments = ["--fixture-health", "--fixture-pack", "--fixture-" + rarity]
            app.launch()
            let tear = app.buttons["pack.tear"]
            XCTAssertTrue(tear.waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts[rarity.capitalized].exists)
            XCTAssertFalse(app.buttons["pack.continue"].exists)
            tear.tap()
            let reveal = app.buttons["pack.reveal"]
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[rarity.capitalized].exists)
            XCTAssertFalse(app.buttons["pack.continue"].exists)
            // Waiting in the opened state must never trigger the second tap.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(reveal.exists)
            reveal.tap()
            XCTAssertTrue(app.buttons["pack.continue"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Your sprout is saved in Storage. Plant it from Edit → Storage → plant details → Place."].exists)
            app.terminate()
        }
    }

    func testReducedMotionPackStillRequiresTwoTaps() {
        let app = XCUIApplication()
        for rarity in ["common", "rare", "epic", "legendary"] {
            app.launchArguments = ["--fixture-health", "--fixture-pack", "--fixture-reduce-motion", "--fixture-" + rarity]
            app.launch()
            XCTAssertTrue(app.buttons["pack.tear"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts[rarity.capitalized].exists)
            app.buttons["pack.tear"].tap()
            XCTAssertTrue(app.buttons["pack.reveal"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[rarity.capitalized].exists)
            Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(app.buttons["pack.continue"].exists)
            app.buttons["pack.reveal"].tap()
            XCTAssertTrue(app.buttons["pack.continue"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testCollectionMenuRoutesAndReturnsToGarden() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]
        app.launch()
        for destination in ["Exchange", "Catalog", "Packs", "Milestones"] {
            let menu = app.buttons["collection.menu"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
            let row = app.buttons["menu.\(destination)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
        }
        app.buttons["Garden"].firstMatch.tap()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 10))
    }

    func testGenericPackKeepsTwoTapOpening() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-pack", "--fixture-generic-pack"]
        app.launch()
        XCTAssertTrue(app.buttons["pack.tear"].waitForExistence(timeout: 15))
        app.buttons["pack.tear"].tap()
        XCTAssertTrue(app.buttons["pack.reveal"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["pack.continue"].exists)
        app.buttons["pack.reveal"].tap()
        XCTAssertTrue(app.buttons["pack.continue"].waitForExistence(timeout: 5))
    }

    func testDevelopmentConnectionUsesExplicitURLAndSecureTokenEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["settings.developer"].tap()
        let connection = app.buttons["settings.connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        connection.tap()
        XCTAssertTrue(app.textFields["connection.url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["connection.token"].exists)
        XCTAssertTrue(app.buttons["connection.connect"].exists)
    }

    func testGardenOpensWithoutHealthAndPlantsHaveDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]
        app.launch()
        let information = app.buttons["garden.info"]
        XCTAssertTrue(information.waitForExistence(timeout: 15))
        information.tap()
        app.buttons["garden.samplePlants"].tap()
        XCTAssertTrue(app.navigationBars["Garden plants"].waitForExistence(timeout: 5))
        let firstPlant = app.cells.firstMatch
        XCTAssertTrue(firstPlant.waitForExistence(timeout: 5))
        firstPlant.tap()
        XCTAssertTrue(app.staticTexts["Growth stage"].waitForExistence(timeout: 5))
    }

    func testFixtureActivityWorksWithoutSystemPermissionSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]
        app.launch()
        app.buttons["navigation.Activity"].tap()
        let connect = app.buttons["activity.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample activity · not your Health data"].exists)
    }

    func testEmptyActivityExplainsMissingData() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--empty-health"]
        app.launch()
        app.buttons["navigation.Activity"].tap()
        app.buttons["activity.connect"].tap()
        XCTAssertTrue(app.staticTexts["No readable step data for today."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Permission denied"].exists)
    }
}
