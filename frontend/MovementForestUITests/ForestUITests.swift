import XCTest
import UIKit

final class ForestUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAuthTitleFollowsResolvedSessionAndHistory() {
        for (scenario, label) in [("--auth-first", "Play"), ("--auth-guest", "Continue your garden"),
                                  ("--auth-linked", "Continue your garden"), ("--auth-signed-out", "Play")] {
            let app = XCUIApplication()
            app.launchArguments = ["--fixture-auth", scenario]
            app.launch()
            let action = app.buttons["title.primary"]
            XCTAssertTrue(action.waitForExistence(timeout: 15))
            XCTAssertEqual(action.label, label)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            let title = app.descendants(matching: .any).matching(identifier: "auth.title").firstMatch
            let window = app.windows.firstMatch
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.frame.minY, window.frame.minY, accuracy: 1)
            XCTAssertEqual(title.frame.maxY, window.frame.maxY, accuracy: 1)
            if scenario == "--auth-signed-out" {
                XCTAssertTrue(app.buttons["title.signIn"].exists)
                action.tap()
                XCTAssertTrue(app.alerts["Start a new garden?"].waitForExistence(timeout: 5))
                app.alerts.buttons["Cancel"].tap()
                XCTAssertEqual(action.label, "Play")
            } else if scenario != "--auth-first" {
                XCTAssertFalse(app.buttons["title.signIn"].exists)
                XCTAssertFalse(app.buttons["Sign in another way"].exists)
                XCTAssertFalse(app.buttons["Start a new garden"].exists)
            }
            app.terminate()
        }
    }

    func testUnresolvedAuthNeverOffersPlay() {
        for scenario in ["--auth-restoring", "--auth-unavailable"] {
            let app = XCUIApplication()
            app.launchArguments = ["--fixture-auth", scenario]
            app.launch()
            XCTAssertTrue(app.staticTexts[scenario == "--auth-restoring" ? "Finding your garden…" : "Saved sign-in unavailable."].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["title.primary"].exists)
            app.terminate()
        }
    }

    func testReturningGuestCanRetryWithoutNewGardenOrSignInActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-auth", "--auth-guest"]
        app.launch()
        let retry = app.staticTexts["title.connectionRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        let action = app.buttons["title.primary"]
        action.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertEqual(action.label, "Continue your garden")
        XCTAssertFalse(app.buttons["title.signIn"].exists)
        XCTAssertFalse(app.buttons["Play"].exists)
    }

    func testGuestSwitchWarningAndCancelAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-auth", "--auth-guest", "--auth-account", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let switchAccount = app.buttons["account.switch"]
        XCTAssertTrue(switchAccount.waitForExistence(timeout: 15))
        if !switchAccount.isHittable { app.scrollViews.firstMatch.swipeUp() }
        switchAccount.tap()
        XCTAssertTrue(app.staticTexts["This guest garden may be lost after switching accounts."].waitForExistence(timeout: 5))
        app.buttons["Keep this garden"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "account.page").firstMatch.waitForExistence(timeout: 5))
    }

    func testPasswordSettingsAppearOnlyAfterEmailAccessIsSetUp() {
        for scenario in ["--auth-guest", "--auth-google-only", "--auth-email-only", "--auth-linked"] {
            let app = XCUIApplication()
            app.launchArguments = ["--fixture-auth", scenario, "--auth-account"]
            app.launch()
            let page = app.descendants(matching: .any).matching(identifier: "account.page").firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 15))
            let hasPassword = scenario == "--auth-email-only" || scenario == "--auth-linked"
            XCTAssertEqual(app.buttons["account.emailSettings"].exists, hasPassword)
            XCTAssertEqual(app.buttons["account.emailLink"].exists, !hasPassword)
            app.terminate()
        }
    }

    func testGuestEmailLinkKeepsAccountAndExposesSettingsAfterPassword() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-auth", "--auth-guest", "--auth-account"]
        app.launch()
        let link = app.buttons["account.emailLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 15)); link.tap()
        let email = app.textFields["account.linkEmailAddress"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); email.tap(); email.typeText("player@example.invalid")
        app.buttons["Continue"].tap()
        let code = app.textFields["account.emailCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5)); code.tap(); code.typeText("123456")
        app.buttons["Verify email"].tap()
        let password = app.secureTextFields["account.newPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 5)); password.tap(); password.typeText("fixture-password")
        let confirmation = app.secureTextFields["account.confirmPassword"]
        confirmation.tap(); confirmation.typeText("fixture-password")
        let finish = app.buttons["account.finishEmailLink"]
        if !finish.isHittable { app.scrollViews.firstMatch.swipeUp() }
        finish.tap()
        XCTAssertTrue(app.buttons["account.emailSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.emailLink"].exists)
        XCTAssertTrue(app.buttons["account.googleLink"].exists)
    }

    func testMilestoneSelectorsAndScrollSurviveRepeatedCachedEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection", "--fixture-milestones"]
        app.launch()
        let pages = app.segmentedControls
        XCTAssertTrue(pages.buttons["Milestones"].waitForExistence(timeout: 15))
        pages.buttons["Milestones"].tap()
        let list = app.scrollViews["milestones.list"]
        let steps = app.buttons["milestones.trackMenu"].exists
            ? app.buttons["milestones.trackMenu"] : app.buttons["milestones.track.steps"]
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        assertMilestoneSelectorPainted(steps, in: app)
        // Re-entry must also paint correctly without scrolling on the first visit.
        pages.buttons["Packs"].tap()
        pages.buttons["Milestones"].tap()
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        app.buttons["Refresh collection"].tap()
        assertMilestoneSelectorPainted(steps, in: app)
        for _ in 0..<3 {
            XCTAssertTrue(steps.waitForExistence(timeout: 5))
            XCTAssertTrue(steps.isHittable)
            XCTAssertGreaterThanOrEqual(steps.frame.height, 44)
            XCTAssertLessThanOrEqual(steps.frame.maxY, list.frame.minY + 1)
            assertMilestoneSelectorPainted(steps, in: app)
            list.swipeUp()
            list.swipeUp()
            let visibleRows = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "milestones.row."))
                .allElementsBoundByIndex.filter {
                    $0.frame.height > 0 && $0.frame.minY >= list.frame.minY && $0.frame.minY < list.frame.maxY
                }
            let anchor = try XCTUnwrap(visibleRows.min { $0.frame.minY < $1.frame.minY })
            let identifier = anchor.identifier
            pages.buttons["Packs"].tap()
            XCTAssertFalse(steps.exists)
            pages.buttons["Milestones"].tap()
            let restored = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            let restoredInViewport = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                restored.exists && restored.frame.height > 0 && list.frame.intersects(restored.frame)
            }, object: nil)
            wait(for: [restoredInViewport], timeout: 5)
            XCTAssertTrue(steps.isHittable)
            assertMilestoneSelectorPainted(steps, in: app)
            XCTAssertFalse(app.staticTexts["Reward saved"].exists)
        }
        for track in ["butterfly", "growth", "special", "event"] {
            selectMilestoneTrack(track, in: app)
            if track == "special" {
                let title = app.staticTexts["At least 10,000 steps in one day"]
                XCTAssertTrue(title.waitForExistence(timeout: 5))
                XCTAssertGreaterThanOrEqual(title.frame.minX, list.frame.minX)
                XCTAssertLessThanOrEqual(title.frame.maxX, list.frame.maxX)
            }
        }
        XCTAssertTrue(app.staticTexts["No active event."].waitForExistence(timeout: 5))
        pages.buttons["Packs"].tap()
        pages.buttons["Milestones"].tap()
        XCTAssertTrue(app.staticTexts["No active event."].waitForExistence(timeout: 5))
        selectMilestoneTrack("event", in: app)
        assertMilestoneSelection("event", in: app)
        XCTAssertEqual(app.staticTexts["fixture.collectionRequests"].value as? String, "0")
    }

    func testMilestonesWrapLongRequirementsAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection", "--fixture-milestones",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let page = app.segmentedControls.buttons["Milestones"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        page.tap()
        selectMilestoneTrack("special", in: app)
        let list = app.scrollViews["milestones.list"]
        let title = app.staticTexts["At least 10,000 steps in one day"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.height, 0)
        XCTAssertGreaterThanOrEqual(title.frame.minX, list.frame.minX)
        XCTAssertLessThanOrEqual(title.frame.maxX, list.frame.maxX)
        let claim = app.buttons["milestone.special_day_10000"]
        XCTAssertTrue(claim.exists)
        XCTAssertGreaterThanOrEqual(claim.frame.height, 44)
        XCTAssertGreaterThanOrEqual(claim.frame.minY, title.frame.maxY)
        XCTAssertLessThanOrEqual(claim.frame.maxX, list.frame.maxX)
        app.segmentedControls.buttons["Packs"].tap()
        app.segmentedControls.buttons["Milestones"].tap()
        selectMilestoneTrack("special", in: app)
        assertMilestoneSelection("special", in: app)
        XCTAssertTrue(app.buttons["milestones.trackMenu"].exists)
        assertMilestoneSelectorPainted(app.buttons["milestones.trackMenu"], in: app)
        XCTAssertEqual(app.staticTexts["fixture.collectionRequests"].value as? String, "0")
    }

    func testCompactMilestoneRowsKeepProgressAndRewardButtonsInsideUniformFrames() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection", "--fixture-milestones"]
        app.launch()
        let page = app.segmentedControls.buttons["Milestones"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        page.tap()
        let list = app.scrollViews["milestones.list"]
        var standardRowHeight: CGFloat?
        for track in ["steps", "butterfly", "growth", "special"] {
            selectMilestoneTrack(track, in: app)
            let candidates = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "milestones.row."))
            XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5))
            let visibleRows = candidates.allElementsBoundByIndex.filter {
                $0.frame.height > 0 && $0.frame.minY >= list.frame.minY && $0.frame.maxY <= list.frame.maxY
            }.sorted { $0.frame.minY < $1.frame.minY }
            XCTAssertGreaterThanOrEqual(visibleRows.count, 2)
            let first = try XCTUnwrap(visibleRows.first)
            if let height = standardRowHeight { XCTAssertEqual(first.frame.height, height, accuracy: 1) }
            else { standardRowHeight = first.frame.height }
            for row in visibleRows {
                XCTAssertEqual(row.frame.height, first.frame.height, accuracy: 1)
                XCTAssertGreaterThanOrEqual(row.frame.minX, list.frame.minX)
                XCTAssertLessThanOrEqual(row.frame.maxX, list.frame.maxX)
                let id = String(row.identifier.dropFirst("milestones.row.".count))
                let bar = app.descendants(matching: .any).matching(identifier: "milestones.progress.\(id)").firstMatch
                XCTAssertTrue(bar.exists)
                XCTAssertGreaterThan(bar.frame.height, 0)
                XCTAssertGreaterThanOrEqual(bar.frame.minX, row.frame.minX)
                XCTAssertLessThanOrEqual(bar.frame.maxX, row.frame.maxX)
                XCTAssertGreaterThanOrEqual(bar.frame.minY, row.frame.minY)
                XCTAssertLessThanOrEqual(bar.frame.maxY, row.frame.maxY)
                let claim = app.buttons["milestone.\(id)"]
                if claim.exists {
                    XCTAssertGreaterThanOrEqual(claim.frame.width, 44)
                    XCTAssertGreaterThanOrEqual(claim.frame.height, 44)
                    XCTAssertGreaterThanOrEqual(claim.frame.minX, bar.frame.maxX)
                    XCTAssertLessThanOrEqual(claim.frame.maxX, row.frame.maxX)
                    XCTAssertGreaterThanOrEqual(claim.frame.minY, row.frame.minY)
                    XCTAssertLessThanOrEqual(claim.frame.maxY, row.frame.maxY)
                }
            }
        }
        XCTAssertEqual(app.staticTexts["fixture.collectionRequests"].value as? String, "0")
    }

    private func selectMilestoneTrack(_ track: String, in app: XCUIApplication) {
        let menu = app.buttons["milestones.trackMenu"]
        if menu.exists { menu.tap() }
        let button = app.buttons["milestones.track.\(track)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func assertMilestoneSelection(_ track: String, in app: XCUIApplication) {
        let menu = app.buttons["milestones.trackMenu"]
        if menu.exists { XCTAssertEqual(menu.value as? String, track.capitalized) }
        else { XCTAssertTrue(app.buttons["milestones.track.\(track)"].isSelected) }
    }

    private func assertMilestoneSelectorPainted(_ button: XCUIElement, in app: XCUIApplication,
                                               file: StaticString = #filePath, line: UInt = #line) {
        // Accessibility/hit testing also passes for the reported invisible-but-tappable strip.
        let screenshot = app.screenshot()
        guard let image = screenshot.image.cgImage else {
            XCTFail("Could not read selector screenshot", file: file, line: line)
            return
        }
        let scaleX = CGFloat(image.width) / app.frame.width
        let scaleY = CGFloat(image.height) / app.frame.height
        let frame = button.frame
        let rect = CGRect(x: (frame.minX - app.frame.minX) * scaleX,
                          y: (frame.minY - app.frame.minY) * scaleY,
                          width: frame.width * scaleX, height: frame.height * scaleY).integral
        guard let crop = image.cropping(to: rect), crop.width > 0, crop.height > 0 else {
            XCTFail("Selector has no on-screen image", file: file, line: line)
            return
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
            return true
        }
        XCTAssertTrue(rendered, file: file, line: line)
        let inkPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 180 && pixels[$0 + 1] < 180 && pixels[$0 + 2] < 180
        }.count
        if Double(inkPixels) / Double(crop.width * crop.height) <= 0.005 {
            add(XCTAttachment(screenshot: screenshot))
            XCTFail("Selector is tappable but its artwork/text is not painted", file: file, line: line)
        }
    }

    func testLevelUpPopupUsesConfirmedBenefitsAndDoesNotReplayOnNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-level-up"]
        app.launch()
        let dismiss = app.buttons["levelUp.continue"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15))
        let offline = app.descendants(matching: .any).matching(identifier: "levelUp.offlineBenefit").firstMatch
        let plants = app.descendants(matching: .any).matching(identifier: "levelUp.plantBenefit").firstMatch
        XCTAssertTrue(offline.label.contains("Base offline capacity"))
        XCTAssertTrue(offline.label.contains("+75 → 900 total"))
        XCTAssertTrue(plants.label.contains("Plant capacity"))
        XCTAssertTrue(plants.label.contains("+10 → 60 total"))
        let popup = app.descendants(matching: .any).matching(identifier: "levelUp.popup").firstMatch
        XCTAssertLessThan(popup.frame.height, app.windows.firstMatch.frame.height * 0.85,
                          "The ordinary-text celebration should remain a compact card")
        dismiss.tap()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 5))
        app.buttons["account.profile"].tap()
        XCTAssertTrue(app.staticTexts["Capacity"].waitForExistence(timeout: 5))
        app.buttons["accountSheet.done"].tap()
        app.buttons["navigation.Activity"].tap()
        app.buttons["navigation.Garden"].tap()
        XCTAssertFalse(dismiss.exists)
    }

    func testLevelUpPopupKeepsContinueReachableAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-level-up",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let dismiss = app.buttons["levelUp.continue"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15))
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(dismiss.frame))
        dismiss.tap()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 5))
    }

    func testProfileAndHomeShareConfirmedProgressAndReturnToTheSameGarden() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-progression"]
        app.launch()
        let level = app.buttons["home.profile"]
        XCTAssertTrue(level.waitForExistence(timeout: 15))
        let garden = app.descendants(matching: .any).matching(identifier: "garden.scene").firstMatch
        let originalFrame = garden.frame
        XCTAssertTrue(app.buttons["account.profile"].exists)
        XCTAssertTrue(app.buttons["home.gems"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "home.gemProgress").firstMatch.exists,
                       "Detailed gem progress stays in Profile so Home remains compact")
        level.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        let progress = app.descendants(matching: .any).matching(identifier: "profile.levelProgress").firstMatch
        XCTAssertTrue(progress.exists)
        XCTAssertEqual(progress.label, "Account Level 5")
        XCTAssertEqual(progress.value as? String, "22 / 150 XP, towards Level 6, 372 total XP")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile.gems").firstMatch.exists)
        app.buttons["accountSheet.done"].tap()
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        XCTAssertEqual(garden.frame, originalFrame)
        app.buttons["home.gems"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile.gemProgress").firstMatch.waitForExistence(timeout: 5))
        app.buttons["accountSheet.done"].tap()
        app.buttons["navigation.Activity"].tap()
        app.buttons["account.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        app.buttons["accountSheet.done"].tap()
        XCTAssertTrue(app.buttons["navigation.Activity"].isSelected)
    }

    func testProfileRetainsCachedProgressWhenRefreshFails() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-progression", "--fixture-account-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["home.profile"].waitForExistence(timeout: 15))
        app.buttons["account.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["accountProgress.retry"].exists)
        let progress = app.descendants(matching: .any).matching(identifier: "profile.levelProgress").firstMatch
        XCTAssertEqual(progress.label, "Account Level 5")
        app.buttons["accountProgress.retry"].tap()
        XCTAssertEqual(progress.value as? String, "22 / 150 XP, towards Level 6, 372 total XP")
    }

    func testFloatingHomeAlignsActionsAndExposesDirectCollectionShortcuts() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-progression"]
        app.launch()
        let level = app.buttons["home.profile"]
        XCTAssertTrue(level.waitForExistence(timeout: 15))
        let profile = app.buttons["account.profile"], settings = app.buttons["account.settings"]
        let controls = [level, profile, settings]
        for control in controls {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertEqual(control.frame.midY, level.frame.midY, accuracy: 2)
        }
        for index in 1..<controls.count { XCTAssertLessThanOrEqual(controls[index - 1].frame.maxX, controls[index].frame.minX) }
        let info = app.buttons["garden.info"], collect = app.buttons["visitors.claim"]
        XCTAssertGreaterThan(info.frame.minY, collect.frame.minY)
        XCTAssertLessThanOrEqual(info.frame.width, 44.5)
        XCTAssertEqual(info.frame.midX, collect.frame.midX, accuracy: 2)
        XCTAssertFalse(app.buttons["collection.menu"].exists)
        for destination in ["Shop", "Catalog", "Packs", "Milestones", "Expedition"] {
            let shortcut = app.buttons["home.shortcut." + destination]
            XCTAssertTrue(shortcut.isHittable)
            XCTAssertGreaterThanOrEqual(shortcut.frame.height, 44)
        }
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["accountSheet.done"].tap()
        app.buttons["home.shortcut.Shop"].tap()
        XCTAssertTrue(app.navigationBars["Shop"].waitForExistence(timeout: 5))
        app.buttons["navigation.Garden"].tap()
        XCTAssertTrue(app.buttons["navigation.Garden"].isSelected)
    }

    func testProfileRemovesRuleCopyAndKeepsSupportingRecordsExpandable() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-progression"]
        app.launch()
        XCTAssertTrue(app.buttons["account.profile"].waitForExistence(timeout: 15))
        app.buttons["account.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wallet"].exists)
        XCTAssertFalse(app.staticTexts["Every 100 recorded steps earns 1 XP."].exists)
        XCTAssertFalse(app.staticTexts["Earn 1 gem for every 10,000 recorded steps, even when no plant needs water."].exists)
        XCTAssertFalse(app.staticTexts["Account level"].exists)
        XCTAssertFalse(app.staticTexts["Joined"].exists)
        XCTAssertFalse(app.staticTexts["Visitors welcomed"].exists)
        let statistics = app.buttons["profile.moreStatistics"]
        for _ in 0..<5 {
            if statistics.isHittable { break }
            app.swipeUp()
        }
        statistics.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Visitors welcomed,")).firstMatch.exists)
        statistics.tap()
        let details = app.buttons["profile.accountDetails"]
        for _ in 0..<5 {
            if details.isHittable { break }
            app.swipeUp()
        }
        details.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Joined,")).firstMatch.exists)
        XCTAssertTrue(app.buttons["profile.accountAccess"].exists)
    }

    func testProfileJournalPreservesCapacityAndNextLevelDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-level-up"]
        app.launch()
        XCTAssertTrue(app.buttons["levelUp.continue"].waitForExistence(timeout: 15))
        app.buttons["levelUp.continue"].tap()
        XCTAssertTrue(app.buttons["account.profile"].waitForExistence(timeout: 5))
        app.buttons["account.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        let details = app.buttons["profile.levelDetails"]
        for _ in 0..<8 {
            if details.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(details.isHittable)
        XCTAssertGreaterThanOrEqual(details.frame.height, 44)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "profile.visitCapacity").firstMatch.label,
            "Stored visits, 900")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "profile.plantCapacity").firstMatch.label,
            "Plants, 60")
        details.tap()
        for label in ["Base stored visits, 900", "Next level, +60 stored visits", "Level 10, 75 plants"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists)
        }
        details.tap()
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Base stored visits, 900")).firstMatch.exists)
    }

    func testProfileJournalAtLargestTextPreservesZeroProgressAndAccountAccess() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-progression", "--fixture-account-fresh",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["account.profile"].waitForExistence(timeout: 15))
        app.buttons["account.profile"].tap()
        let progress = app.descendants(matching: .any).matching(identifier: "profile.levelProgress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "Account Level 1")
        XCTAssertEqual(progress.value as? String, "0 / 50 XP, towards Level 2, 0 total XP")
        let gems = app.descendants(matching: .any).matching(identifier: "profile.gems").firstMatch
        for _ in 0..<12 {
            if gems.isHittable { break }
            app.swipeUp()
        }
        XCTAssertEqual(gems.label, "Gems, 0")
        let access = app.buttons["profile.accountAccess"]
        for _ in 0..<12 {
            if access.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(access.isHittable)
        XCTAssertGreaterThanOrEqual(access.frame.height, 44)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(access.frame))
        access.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
    }

    func testMyPlantsSwipeRefreshDoesNotLeaveAConnectionFailure() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]
        app.launch()
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 15))
        app.buttons["navigation.My plants"].tap()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeDown()
        let loading = app.staticTexts["Loading your plants…"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["Your garden couldn’t refresh. Try again when connected."].exists)
        XCTAssertFalse(app.staticTexts["Saved plants · Connect to refresh"].exists)
        XCTAssertFalse(app.buttons["Try again"].exists)
        XCTAssertTrue(app.staticTexts["Stored"].exists)
    }

    func testUncachedFailedProfileDoesNotInventBalances() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden", "--fixture-progression", "--fixture-account-failed"]
        app.launch()
        XCTAssertTrue(app.buttons["account.profile"].waitForExistence(timeout: 15))
        app.buttons["account.profile"].tap()
        XCTAssertTrue(app.staticTexts["Your profile is unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["accountProgress.retry"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "profile.gems").firstMatch.exists)
        XCTAssertTrue(app.buttons["profile.accountAccess"].exists)
    }

    func testRewardEffectsFixtureFiltersRecapsAndUpdatesConfirmedCounter() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-effects"]; app.launch()
        XCTAssertTrue(app.buttons["effects.rewardOne"].waitForExistence(timeout: 15))
        app.buttons["effects.rewardOne"].tap()
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["effects.rewardOne"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Visitor tokens, 101")).firstMatch.exists)
        app.buttons["visitors.claim"].tap()
        expectation(for: ready, evaluatedWith: app.buttons["effects.rewardOne"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Visitor tokens, 113")).firstMatch.exists)
        for (button, count) in [("effects.zero", "0"), ("effects.growth", "5"), ("effects.stage", "3"), ("effects.fifteen", "15")] {
            app.buttons[button].tap()
            XCTAssertTrue(app.buttons["effects.continue"].waitForExistence(timeout: 5))
            if count == "0" { XCTAssertTrue(app.staticTexts["No new confirmed growth."].exists) }
            app.buttons["effects.continue"].tap()
            let recipients = app.staticTexts["effects.recipients"]
            expectation(for: NSPredicate(format: "value == %@", count), evaluatedWith: recipients)
            waitForExpectations(timeout: 5)
        }
    }


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
        XCTAssertTrue(app.staticTexts["Active skills"].exists)
        XCTAssertFalse(app.staticTexts["Garden controls"].exists)
        XCTAssertFalse(app.staticTexts["Visitors"].exists)
    }

    func testStoredProfilesShowTagsMultipliersAndIntegratedGrowth() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        let edit = app.buttons["navigation.Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: edit)
        waitForExpectations(timeout: 10)
        func checkDetails() {
            XCTAssertTrue(app.staticTexts["plantDetails.stage"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["plantDetails.stage"].label.contains("·"))
            XCTAssertTrue(app.descendants(matching: .any)["plantDetails.tags"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["plantDetails.growthBar"].exists)
            let water = app.descendants(matching: .any)["plantDetails.waterProgress"]
            XCTAssertTrue(water.exists)
            XCTAssertTrue((water.value as? String)?.contains(" of ") == true)
            XCTAssertFalse(app.staticTexts["Total water"].exists)
            XCTAssertFalse(app.buttons["Growth details"].exists)
            let multiplier = app.descendants(matching: .any)["plantDetails.multiplier.steps"]
            let content = app.scrollViews["plantDetails.content"]
            for _ in 0..<3 {
                if multiplier.exists { break }
                content.swipeUp()
            }
            XCTAssertTrue(multiplier.exists)
            XCTAssertFalse(app.staticTexts["Activity multipliers unavailable"].exists)
            app.buttons["plantDetails.close"].tap()
        }
        app.buttons["navigation.My plants"].tap()
        let owned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.stored.")).firstMatch
        XCTAssertTrue(owned.waitForExistence(timeout: 5)); owned.tap()
        checkDetails()
        app.buttons["navigation.Edit"].tap()
        app.buttons["editor.storage"].tap()
        let stored = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.copy.")).firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 5)); stored.tap()
        checkDetails()
    }

    func testEditorSkillsStartsClosedAndClosesWithoutLeavingEdit() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        let edit = app.buttons["navigation.Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: edit); waitForExpectations(timeout: 10)
        edit.tap()
        let skills = app.buttons["editor.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["garden.skills.close"].exists)
        skills.tap()
        XCTAssertTrue(app.buttons["garden.skills.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Inactive skills"].exists)
        app.buttons["garden.skills.close"].tap()
        XCTAssertTrue(app.buttons["editor.saveGarden"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.saveGarden"].isHittable)
        XCTAssertFalse(app.buttons["editor.saveGarden"].isEnabled)
        XCTAssertTrue(app.buttons["editor.done"].exists)
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
        XCTAssertTrue(app.staticTexts["plantDetails.stage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.place"].exists); XCTAssertFalse(app.buttons["editor.move"].exists)
        app.buttons["plantDetails.close"].tap()
        app.buttons["navigation.Edit"].tap()
        XCTAssertTrue(app.buttons["editor.done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation.My plants"].exists); XCTAssertFalse(app.buttons["collection.menu"].exists)
        app.buttons["editor.storage"].tap()
        let stored = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.copy.")).firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 5))
        app.buttons["Common"].firstMatch.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Close explanation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.place"].exists)
        app.buttons["Close explanation"].tap()
        stored.tap()
        XCTAssertTrue(app.buttons["editor.place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.apply"].exists)
        app.buttons["editor.place"].tap()
        XCTAssertTrue(app.buttons["editor.cancel"].waitForExistence(timeout: 5))
        app.buttons["editor.position"].tap()
        XCTAssertTrue(app.textFields["editor.x"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["editor.y"].exists); XCTAssertTrue(app.textFields["editor.angle"].exists)
        let positionPanel = app.descendants(matching: .any).matching(identifier: "editor.positionPanel").firstMatch
        let liveGarden = app.descendants(matching: .any).matching(identifier: "garden.scene").firstMatch
        XCTAssertTrue(liveGarden.exists); XCTAssertGreaterThan(liveGarden.frame.height, 0)
        XCTAssertGreaterThanOrEqual(positionPanel.frame.minY, liveGarden.frame.minY - 1)
        XCTAssertLessThan(positionPanel.frame.minY, liveGarden.frame.maxY)
        XCTAssertFalse(app.navigationBars["Position plant"].exists)
        app.buttons["editor.cancel"].tap()
        app.buttons["editor.storage"].tap(); stored.tap(); app.buttons["editor.place"].tap()
        app.buttons["editor.apply"].tap()
        let rotate = app.buttons["editor.rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        expectation(for: ready, evaluatedWith: rotate); waitForExpectations(timeout: 10)
        let popup = app.descendants(matching: .any).matching(identifier: "garden.selection").firstMatch
        XCTAssertTrue(popup.exists)
        XCTAssertGreaterThanOrEqual(popup.frame.minY, liveGarden.frame.minY - 1)
        XCTAssertLessThanOrEqual(popup.frame.maxY, liveGarden.frame.maxY + 1)
        app.buttons["editor.store"].press(forDuration: 0.6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["editor.store"].waitForExistence(timeout: 5), "Holding an action icon must not store the plant")
        app.buttons["editor.move"].tap()
        XCTAssertFalse(app.switches["editor.adult"].exists)
        app.buttons["editor.cancel"].tap()
        rotate.tap()
        let slider = app.sliders["editor.rotation"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["editor.adult"].exists)
        let garden = app.descendants(matching: .any).matching(identifier: "garden.scene").firstMatch
        XCTAssertTrue(garden.exists); XCTAssertTrue(garden.isHittable)
        XCTAssertGreaterThanOrEqual(slider.frame.minY, garden.frame.minY - 1)
        XCTAssertLessThanOrEqual(slider.frame.maxY, garden.frame.maxY + 1)
        XCTAssertFalse(app.navigationBars["Rotate plant"].exists)
        let angle = app.textFields["editor.angle"]
        let originalAngle = angle.value as? String
        slider.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertNotEqual(angle.value as? String, originalAngle)
        app.buttons["editor.cancel"].tap()
        XCTAssertTrue(rotate.waitForExistence(timeout: 5)); rotate.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(angle.value as? String, originalAngle, "Cancel must restore the saved angle")
        slider.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["editor.apply"].tap()
        XCTAssertTrue(rotate.waitForExistence(timeout: 10))
        expectation(for: ready, evaluatedWith: rotate); waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["editor.unsavedChanges"].exists)
        let impact = app.descendants(matching: .any).matching(identifier: "editor.actionImpact").firstMatch
        XCTAssertTrue(impact.exists)
        XCTAssertLessThanOrEqual(impact.frame.maxY, popup.frame.minY, "Storage impact belongs at the top, above the selection popup")
        XCTAssertFalse(app.staticTexts["First qualifying source added"].exists)
        XCTAssertFalse(app.staticTexts["Last qualifying source removed"].exists)
        let saveGarden = app.buttons["editor.saveGarden"]
        XCTAssertTrue(saveGarden.isEnabled)
        XCTAssertTrue(saveGarden.isHittable, "The Save tick must remain reachable in the navigation toolbar")
        XCTAssertGreaterThanOrEqual(saveGarden.frame.height, 44)
        XCTAssertGreaterThanOrEqual(saveGarden.frame.width, 44)
        XCTAssertLessThanOrEqual(saveGarden.frame.width, 64)
        let close = app.buttons["editor.done"]
        XCTAssertLessThanOrEqual(saveGarden.frame.maxX, close.frame.minX + 1)
        XCTAssertEqual(saveGarden.frame.midY, close.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(saveGarden.frame.maxY, popup.frame.minY)
        app.buttons["editor.done"].tap()
        XCTAssertTrue(app.alerts["Save garden changes?"].waitForExistence(timeout: 5))
        app.alerts["Save garden changes?"].buttons["Keep editing"].tap()
        XCTAssertTrue(saveGarden.isHittable)
        saveGarden.tap()
        XCTAssertTrue(app.buttons["navigation.My plants"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Saved."].exists)
        app.buttons["navigation.My plants"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.planted.")).firstMatch.waitForExistence(timeout: 5))
    }

    func testJournalRarityExplanationDoesNotOpenOrChangeAnOwnedCopy() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        XCTAssertTrue(app.buttons["navigation.My plants"].waitForExistence(timeout: 15))
        app.buttons["navigation.My plants"].tap()
        let rarity = app.buttons["Common"].firstMatch
        XCTAssertTrue(rarity.waitForExistence(timeout: 5))
        rarity.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Close explanation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["plantDetails.close"].exists)
        app.buttons["Close explanation"].tap()
        let stored = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "myplants.stored.")).firstMatch
        stored.tap()
        XCTAssertTrue(app.buttons["plantDetails.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.place"].exists)
        XCTAssertFalse(app.staticTexts["catalog.description"].exists)
        XCTAssertFalse(app.staticTexts["Stored plants do not grow."].exists)
        app.buttons["plantDetails.close"].tap()
        XCTAssertTrue(stored.waitForExistence(timeout: 5))
    }

    func testJournalCatalogKeepsSpeciesNavigationVariantSelectionAndStageFactsReadOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection"]; app.launch()
        XCTAssertTrue(app.buttons["Catalog"].waitForExistence(timeout: 15)); app.buttons["Catalog"].tap()
        let plants = app.descendants(matching: .any)["catalog.collection.plants"]
        let variants = app.descendants(matching: .any)["catalog.collection.variants"]
        XCTAssertTrue(plants.waitForExistence(timeout: 5))
        XCTAssertTrue(variants.exists)
        // This fixture has no confirmed discovery service; it must never imply zero acquisitions.
        XCTAssertEqual(plants.value as? String, "Unavailable")
        XCTAssertEqual(variants.value as? String, "Unavailable")
        let oak = app.buttons["catalog.species.oak"]
        XCTAssertTrue(oak.waitForExistence(timeout: 5)); oak.tap()
        let blue = app.buttons["catalog.variant.blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 5))
        let standard = app.buttons["catalog.variant.standard"]
        XCTAssertTrue(standard.isSelected)
        XCTAssertLessThan(standard.frame.minX, blue.frame.minX)
        blue.tap()
        XCTAssertTrue(blue.isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["plantDetails.tags"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["catalog.stage.sprout"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["catalog.stage.adult"].exists)
        XCTAssertFalse(app.staticTexts["Grow this variant to discover its later stages."].exists)
        XCTAssertFalse(app.staticTexts["Movement Forest initial collection."].exists)
        XCTAssertFalse(app.staticTexts["Clearance & plant information"].exists)
        XCTAssertFalse(app.buttons["editor.place"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let requests = app.staticTexts["fixture.collectionRequests"]
        XCTAssertEqual(requests.value as? String, "0")
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

    func testUnfinishedDraftUsesEditBadgeAndResumesThroughEdit() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        let edit = app.buttons["navigation.Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: edit); waitForExpectations(timeout: 10)
        XCTAssertNotEqual(edit.value as? String, "Unsaved garden changes")
        edit.tap()
        app.buttons["editor.storage"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.copy.")).firstMatch.tap()
        app.buttons["editor.place"].tap()
        app.buttons["editor.apply"].tap()
        XCTAssertTrue(app.staticTexts["editor.unsavedChanges"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertEqual(edit.value as? String, "Unsaved garden changes")
        XCTAssertFalse(app.staticTexts["Unfinished garden draft"].exists)
        XCTAssertFalse(app.buttons["editor.resumeDraft"].exists)
        edit.tap()
        XCTAssertTrue(app.staticTexts["editor.unsavedChanges"].waitForExistence(timeout: 5))
        app.buttons["editor.saveGarden"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertNotEqual(edit.value as? String, "Unsaved garden changes")
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
            XCTAssertFalse(app.buttons["Continue later"].exists)
            XCTAssertFalse(app.staticTexts[rarity.capitalized].exists)
            XCTAssertFalse(app.buttons["pack.continue"].exists)
            tear.tap()
            let reveal = app.buttons["pack.reveal"]
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Continue later"].exists)
            XCTAssertTrue(app.staticTexts[rarity.capitalized].exists)
            XCTAssertFalse(app.buttons["pack.continue"].exists)
            // Waiting in the opened state must never trigger the second tap.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(reveal.exists)
            reveal.tap()
            XCTAssertTrue(app.buttons["pack.continue"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[rarity.capitalized].exists)
            XCTAssertFalse(app.staticTexts["Saved to Storage."].exists)
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

    func testInterruptedConfirmedPackKeepsResultWithoutReplayingOrOpeningAgain() {
        let app = XCUIApplication()
        for stage in ["sealed", "tearing", "opened", "revealing", "result"] {
            app.launchArguments = ["--fixture-health", "--fixture-pack", "--fixture-legendary"]
            app.launch()
            XCTAssertTrue(app.buttons["pack.tear"].waitForExistence(timeout: 15))
            if stage != "sealed" {
                app.buttons["pack.tear"].tap()
            }
            if stage == "opened" || stage == "revealing" || stage == "result" {
                XCTAssertTrue(app.buttons["pack.reveal"].waitForExistence(timeout: 5))
            }
            if stage == "revealing" || stage == "result" {
                app.buttons["pack.reveal"].tap()
            }
            if stage == "result" {
                XCTAssertTrue(app.buttons["pack.continue"].waitForExistence(timeout: 5))
            }
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(app.staticTexts["fixture.savedOpening"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["pack.tear"].exists); XCTAssertFalse(app.buttons["pack.reveal"].exists)
            XCTAssertEqual(app.staticTexts["fixture.openingCount"].value as? String, "1")
            app.buttons["fixture.viewResult"].tap()
            XCTAssertTrue(app.buttons["pack.continue"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["pack.tear"].exists); XCTAssertFalse(app.buttons["pack.reveal"].exists)
            app.buttons["pack.continue"].tap()
            XCTAssertTrue(app.staticTexts["fixture.savedOpening"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["fixture.openingCount"].value as? String, "1")
            app.terminate()
        }
    }

    func testCollectionShortcutsReturnToGardenWithoutLegacyDrawer() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]
        app.launch()
        for destination in ["Shop", "Catalog", "Packs", "Milestones", "Expedition"] {
            let shortcut = app.buttons["home.shortcut.\(destination)"]
            XCTAssertTrue(shortcut.waitForExistence(timeout: 10))
            shortcut.tap()
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["collection.menu"].exists)
            let back = app.buttons["navigation.backToGarden"]
            XCTAssertTrue(back.isHittable)
            back.tap()
            XCTAssertTrue(app.buttons["home.shortcut.Shop"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["garden.info"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        app.buttons["settings.gameHelp"].tap()
        app.buttons["garden.samplePlants"].tap()
        XCTAssertTrue(app.navigationBars["Garden plants"].waitForExistence(timeout: 5))
        let firstPlant = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "garden.browser.")).firstMatch
        XCTAssertTrue(firstPlant.waitForExistence(timeout: 5))
        firstPlant.tap()
        XCTAssertTrue(app.staticTexts["plantDetails.stage"].waitForExistence(timeout: 5))
    }

    func testGameHelpKeepsControlsOutOfGardenInfoAndRevealsThemOnDemand() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-garden"]; app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        app.buttons["settings.gameHelp"].tap()
        XCTAssertTrue(app.navigationBars["Game help"].waitForExistence(timeout: 5))
        let instructions = app.staticTexts["Drag to orbit · Pinch to zoom · Two fingers to pan"]
        XCTAssertFalse(instructions.exists)
        app.buttons["help.controls"].tap()
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        app.buttons["help.controls"].tap()
        XCTAssertFalse(instructions.exists)
    }

    func testPackInspectionAndCancelledConfirmationsNeverMutateAndPurchaseKeepsQuantity() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection"]; app.launch()
        let purchase = app.buttons["collection.exchange.woodland"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", ": Not enough ")).firstMatch.exists)
        let purchaseTop = purchase.frame.minY
        let requests = app.staticTexts["fixture.collectionRequests"]
        let tokens = app.staticTexts["fixture.collectionTokens"]
        let packs = app.staticTexts["fixture.collectionPacks"]
        XCTAssertEqual(requests.value as? String, "0")
        XCTAssertEqual(tokens.value as? String, "14")
        app.buttons["collection.offerContents.woodland"].tap()
        let odds = app.descendants(matching: .any).matching(identifier: "pack.variant.common.oak.standard").firstMatch
        XCTAssertTrue(odds.waitForExistence(timeout: 5))
        app.buttons["packContents.close"].tap()
        XCTAssertEqual(requests.value as? String, "0")

        purchase.tap()
        XCTAssertTrue(app.buttons["purchase.confirm"].waitForExistence(timeout: 5))
        app.buttons["purchase.cancel"].tap()
        XCTAssertEqual(requests.value as? String, "0")
        XCTAssertEqual(tokens.value as? String, "14")
        purchase.tap()
        let quantity = app.steppers["purchase.quantity"]
        XCTAssertTrue(quantity.waitForExistence(timeout: 5))
        quantity.buttons["Increment"].tap() // Two Woodland packs cost ten tokens.
        quantity.buttons["Increment"].tap() // Three are unaffordable.
        XCTAssertFalse(app.buttons["purchase.confirm"].isEnabled)
        quantity.buttons["Decrement"].tap()
        XCTAssertTrue(app.buttons["purchase.confirm"].isEnabled)
        app.buttons["purchase.confirm"].tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: requests)
        expectation(for: NSPredicate(format: "value == %@", "3"), evaluatedWith: packs)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(tokens.value as? String, "4")
        XCTAssertEqual(packs.value as? String, "3")
        let closeNotice = app.buttons["shop.purchaseNotice.close"]
        XCTAssertTrue(closeNotice.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Packs saved to Inventory."].exists)
        XCTAssertEqual(purchase.frame.minY, purchaseTop, accuracy: 1, "Purchase feedback must not move the Shop content")
        XCTAssertGreaterThanOrEqual(closeNotice.frame.height, 44)
        closeNotice.tap()
        XCTAssertFalse(closeNotice.exists)
        app.buttons["Refresh collection"].tap()
        XCTAssertFalse(closeNotice.exists, "Refreshing must not replay a dismissed receipt")
        XCTAssertEqual(requests.value as? String, "1", "Closing/refreshing feedback must not submit another purchase")

        app.segmentedControls.buttons["Packs"].tap()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.open.")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.alerts["Open pack?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(requests.value as? String, "1")
        XCTAssertEqual(packs.value as? String, "3")
        XCTAssertFalse(app.staticTexts["Opening history"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Last confirmed result"].exists)
        let lastResult = app.descendants(matching: .any).matching(identifier: "packs.lastResult").firstMatch
        XCTAssertTrue(lastResult.exists)
        XCTAssertLessThanOrEqual(lastResult.frame.height, 144)
        app.segmentedControls.buttons["Exchange"].tap()
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        XCTAssertFalse(closeNotice.exists, "Returning to Shop must not replay a saved receipt")
    }

    func testShopPurchaseNotificationDismissesAutomaticallyWithoutAnotherRequest() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection"]; app.launch()
        let purchase = app.buttons["collection.exchange.woodland"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        let purchaseTop = purchase.frame.minY
        purchase.tap()
        let confirm = app.buttons["purchase.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let closeNotice = app.buttons["shop.purchaseNotice.close"]
        XCTAssertTrue(closeNotice.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pack saved to Inventory."].exists)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: closeNotice)
        waitForExpectations(timeout: 7)
        XCTAssertEqual(app.staticTexts["fixture.collectionRequests"].value as? String, "1")
        XCTAssertEqual(purchase.frame.minY, purchaseTop, accuracy: 1)
    }

    func testPackContentsListsVariantOddsWithoutArtworkOrExpansionAndNeverPurchases() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection"]; app.launch()
        let inspect = app.buttons["collection.offerContents.woodland"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 15))
        inspect.press(forDuration: 0.7)
        let close = app.buttons["packContents.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        for variant in ["standard", "blue", "vined"] {
            let row = app.descendants(matching: .any).matching(identifier: "pack.variant.common.oak.\(variant)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.label.contains("%"))
            XCTAssertTrue(row.label.contains("Oak"))
        }
        XCTAssertFalse(app.buttons["pack.species.common.oak"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Within Common:")).firstMatch.exists)
        close.tap()
        XCTAssertEqual(app.staticTexts["fixture.collectionRequests"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["fixture.collectionTokens"].value as? String, "14")
    }

    func testJournalPurchaseKeepsFooterReachableWithAccessibilityText() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health", "--fixture-collection",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let purchase = app.buttons["collection.exchange.woodland"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        for _ in 0..<4 {
            if purchase.isHittable { break }
            app.swipeUp()
        }
        purchase.tap()
        let confirm = app.buttons["purchase.confirm"], cancel = app.buttons["purchase.cancel"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable); XCTAssertTrue(cancel.isHittable)
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        XCTAssertLessThanOrEqual(confirm.frame.maxY, app.frame.maxY)
        let content = app.scrollViews["purchase.content"]
        XCTAssertTrue(content.exists)
        content.swipeUp()
        XCTAssertTrue(confirm.isHittable); XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertEqual(app.staticTexts["fixture.collectionRequests"].value as? String, "0")
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

    func testActivityStripScrollsThroughEveryTrackedDailyTotal() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-health"]; app.launch()
        XCTAssertTrue(app.buttons["navigation.Activity"].waitForExistence(timeout: 15))
        app.buttons["navigation.Activity"].tap()
        XCTAssertTrue(app.buttons["activity.connect"].waitForExistence(timeout: 5))
        app.buttons["activity.connect"].tap()
        let strip = app.scrollViews["activity.totals.scroll"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        for metric in ["steps", "distance", "energy", "flights", "workouts", "workoutMinutes"] {
            let item = app.descendants(matching: .any).matching(identifier: "activity.total." + metric).firstMatch
            for _ in 0..<6 {
                if item.isHittable { break }
                strip.swipeLeft()
            }
            XCTAssertTrue(item.exists, "Missing activity metric: " + metric)
        }
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
