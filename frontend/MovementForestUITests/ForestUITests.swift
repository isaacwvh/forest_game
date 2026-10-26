import XCTest

final class ForestUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
            XCTAssertTrue(app.staticTexts["Your sprout is saved in Storage. Plant it from Garden → Storage."].exists)
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
        XCTAssertTrue(app.buttons["garden.plants"].waitForExistence(timeout: 10))
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
        let plants = app.buttons["garden.plants"]
        XCTAssertTrue(plants.waitForExistence(timeout: 15))
        plants.tap()
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
        app.tabBars.buttons["Activity"].tap()
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
        app.tabBars.buttons["Activity"].tap()
        app.buttons["activity.connect"].tap()
        XCTAssertTrue(app.staticTexts["No readable step data for today."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Permission denied"].exists)
    }
}
