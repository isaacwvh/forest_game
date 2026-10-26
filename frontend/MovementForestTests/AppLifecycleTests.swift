import XCTest
import Foundation
import Combine
@testable import MovementForest

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testPublishedForegroundFollowsEventAndCannotBeOverwrittenByStaleStartupPhase() {
        let resume = AppResumeCoordinator(), recap = AppEntryRecapCoordinator()
        var observed: [Bool] = []
        let updates = resume.$foreground.sink { observed.append($0) }
        defer { updates.cancel() }
        XCTAssertFalse(resume.initializeSceneIfNeeded(to: .inactive, recap: recap))
        XCTAssertTrue(resume.sceneChanged(to: .active, recap: recap))
        XCTAssertTrue(resume.foreground)
        XCTAssertTrue(resume.initializeSceneIfNeeded(to: .inactive, recap: recap))
        XCTAssertTrue(resume.foreground)
        XCTAssertFalse(resume.sceneChanged(to: .background, recap: recap))
        XCTAssertFalse(resume.initializeSceneIfNeeded(to: .active, recap: recap))
        XCTAssertFalse(resume.foreground)
        XCTAssertTrue(resume.sceneChanged(to: .active, recap: recap))
        XCTAssertEqual(observed, [false, true, false, true])
    }

    func testEntryThresholdUsesEachActualAbsenceRatherThanAccumulatingShortTrips() {
        var gate = AppEntryGate()
        let account = UUID()
        XCTAssertTrue(gate.enter(account: account))
        for start in stride(from: 100.0, to: 1000.0, by: 40) {
            gate.background(at: start)
            gate.foreground(at: start + 29.999)
            XCTAssertFalse(gate.enter(account: account))
        }
        gate.background(at: 1000)
        gate.foreground(at: 1030)
        XCTAssertTrue(gate.enter(account: account))
        XCTAssertFalse(gate.enter(account: account))
        gate.background(at: 1100)
        gate.foreground(at: 1131)
        XCTAssertTrue(gate.enter(account: account))
    }

    func testDuplicateBackgroundAndTransientForegroundDoNotInventAnEntry() {
        var gate = AppEntryGate()
        let account = UUID()
        XCTAssertTrue(gate.enter(account: account))
        for _ in 0..<20 {
            gate.foreground(at: 100)
            XCTAssertFalse(gate.enter(account: account))
        }
        gate.background(at: 100)
        gate.background(at: 120)
        gate.foreground(at: 130)
        XCTAssertTrue(gate.enter(account: account), "Duplicate background events must not reset the absence start")
        gate.background(at: 200)
        gate.foreground(at: 190)
        XCTAssertFalse(gate.enter(account: account))
        gate.signOut()
        XCTAssertTrue(gate.enter(account: account))
    }

    func testInactiveDoesNotRepeatConnectionAttemptButBackgroundDoes() async {
        let resume = AppResumeCoordinator()
        var attempts = 0
        resume.activate()
        resume.connectIfNeeded { attempts += 1 }
        for _ in 0..<20 {
            resume.inactive(); resume.activate()
            resume.connectIfNeeded { attempts += 1 }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, 1)
        resume.background(); resume.activate()
        resume.connectIfNeeded { attempts += 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, 2)
        resume.background()
    }
}
