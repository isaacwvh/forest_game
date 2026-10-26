import XCTest
import Combine
@testable import MovementForest

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testHistoryBoundsCountAgeAndEncodedBytes() throws {
        let now = Date(), session = UUID()
        func event(_ date: Date, _ text: String = "confirmed") -> DiagnosticEvent {
            DiagnosticEvent(id: UUID(), date: date, session: session, scope: nil,
                            category: "Garden edit", outcome: text, requestID: UUID().uuidString)
        }
        let recent = (0..<1200).map { _ in event(now) }
        let bounded = DiagnosticHistory.bounded([event(now.addingTimeInterval(-8 * 86400))] + recent, now: now)
        XCTAssertEqual(bounded.count, 1000)
        XCTAssertEqual(bounded.first?.id, recent[200].id)
        let large = (0..<1000).map { _ in event(now, String(repeating: "x", count: 4000)) }
        let limited = DiagnosticHistory.bounded(large, now: now)
        XCTAssertLessThan(limited.count, 1000)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(limited).count, DiagnosticHistory.maximumBytes)
        XCTAssertTrue(DiagnosticHistory.bounded([event(now.addingTimeInterval(-8 * 86400))], now: now).isEmpty)
    }

    func testPersistedHistorySurvivesRecreation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("events.json"), history = DiagnosticHistory(url: url, enabled: true)
        let recorded = expectation(description: "event persisted"), id = UUID().uuidString
        let subscription = history.$events.filter { $0.contains { $0.requestID == id } }.first().sink { _ in recorded.fulfill() }
        history.record("Garden edit", "confirmation unknown", requestID: id)
        await fulfillment(of: [recorded], timeout: 5)
        let reopened = DiagnosticHistory(url: url, enabled: true), restored = expectation(description: "event restored")
        let next = reopened.$events.filter { $0.contains { $0.requestID == id } }.first().sink { _ in restored.fulfill() }
        await fulfillment(of: [restored], timeout: 5)
        withExtendedLifetime([subscription, next]) { }
    }

    func testPlayerErrorsDoNotExposeRawServerMessages() {
        let raw = "internal receipt verification payload requestId=secret"
        for status in [401, 409, 422, 429, 500] {
            let text = PlayerMessage.failure(APIError(status: status, code: "internal", message: raw))
            XCTAssertFalse(text.contains(raw)); XCTAssertFalse(text.contains("requestId"))
        }
    }

    func testDisabledDiagnosticsNeverCreateAHistoryFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let history = DiagnosticHistory(url: url, enabled: false)
        history.record("Garden edit", "confirmed"); history.setScope("another account")
        XCTAssertTrue(history.events.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAccountScopesHideOtherAccountsAndKeepGeneralEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DiagnosticHistory(url: folder.appendingPathComponent("events.json"), enabled: true)
        let first = expectation(description: "first account events")
        let subscription = history.$events.filter { $0.contains { $0.scope == "A" } }.first().sink { events in
            XCTAssertFalse(events.contains { $0.scope == "B" }); first.fulfill()
        }
        history.record("Lifecycle", "general")
        history.record("Garden edit", "first account", scope: "A")
        history.record("Garden edit", "second account", scope: "B")
        history.setScope("A")
        await fulfillment(of: [first], timeout: 5)
        let second = expectation(description: "second account events")
        let next = history.$events.filter { $0.contains { $0.scope == "B" } }.first().sink { events in
            XCTAssertFalse(events.contains { $0.scope == "A" }); XCTAssertTrue(events.contains { $0.scope == nil }); second.fulfill()
        }
        history.setScope("B")
        await fulfillment(of: [second], timeout: 5)
        withExtendedLifetime([subscription, next]) { }
    }

    func testExportUsesOnlyAllowlistedMetadata() throws {
        let event = DiagnosticEvent(id: UUID(), date: Date(), session: UUID(), scope: nil,
                                    category: "Activity", outcome: "confirmed", requestID: UUID().uuidString)
        let data = try XCTUnwrap(DiagnosticHistory.export([event]).data(using: .utf8))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), Set(["id", "date", "session", "category", "outcome", "requestID"]))
    }
}
