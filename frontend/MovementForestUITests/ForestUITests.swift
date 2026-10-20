import XCTest

final class ForestUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
