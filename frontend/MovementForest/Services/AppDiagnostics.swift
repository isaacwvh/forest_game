import Foundation
import Combine

/// Presentation metadata only; journals and confirmed state remain authoritative.
struct GardenFeedback: Equatable {
    enum Kind: Equatable { case success, pending, failure, uncertain, offline, locked, information }
    enum Source: Equatable { case gardenRead, gardenEdit, inventory, visitorConnection, visitorReward, visitorSession }
    let id = UUID()
    let text: String
    let kind: Kind
    let source: Source
    var visibleInGarden: Bool { kind != .success }
}

enum InternalTools {
    static var enabled: Bool {
        #if DEBUG || INTERNAL_TOOLS
        return true
        #else
        return false
        #endif
    }
}

struct DiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let session: UUID
    let scope: String?
    let category: String
    let outcome: String
    let requestID: String?
}

/// Local, bounded, allowlisted metadata only. Never pass headers, tokens or Health bodies.
/// Disk work is serialized off the main/render thread; this store never owns requests.
final class DiagnosticHistory: ObservableObject {
    static let shared = DiagnosticHistory()
    @Published private(set) var events: [DiagnosticEvent] = []
    private let queue = DispatchQueue(label: "MovementForest.Diagnostics", qos: .utility)
    private let url: URL?
    private let session = UUID()
    private var recent: [DiagnosticEvent] = []
    private var currentScope: String?
    private let enabled: Bool
    static let maximumEvents = 1000
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    init(url: URL? = nil, enabled: Bool = InternalTools.enabled) {
        self.enabled = enabled
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("recent.json")
        guard enabled else { return }
        queue.async { [self] in
            if let url = self.url {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if let url = self.url, let data = try? Data(contentsOf: url), data.count <= Self.maximumBytes,
               let saved = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
                recent = saved
            }
            trim(); publish()
        }
    }

    static func scope(server: String, user: UUID) -> String { server + "|" + user.uuidString }

    func setScope(_ scope: String?) {
        guard enabled else { return }
        queue.async { [self] in currentScope = scope; publish() }
    }

    /// Explicit scopes keep late responses attached to their original account.
    func record(_ category: String, _ outcome: String, requestID: String? = nil, scope: String? = nil) {
        guard enabled else { return }
        let date = Date()
        queue.async { [self] in
            recent.append(DiagnosticEvent(id: UUID(), date: date, session: session,
                scope: scope, category: String(category.prefix(80)),
                outcome: String(outcome.prefix(1000)), requestID: requestID.map { String($0.prefix(128)) }))
            trim()
            if let url = url, let data = try? JSONEncoder().encode(recent) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var destination = url, values = URLResourceValues()
                values.isExcludedFromBackup = true; try? destination.setResourceValues(values)
            }
            publish()
        }
    }

    static func bounded(_ events: [DiagnosticEvent], now: Date = Date()) -> [DiagnosticEvent] {
        let encoder = JSONEncoder()
        var result: [DiagnosticEvent] = [], bytes = 2
        for event in events.reversed() where now.timeIntervalSince(event.date) <= maximumAge {
            guard result.count < maximumEvents, let data = try? encoder.encode(event),
                  bytes + data.count + 1 <= maximumBytes else { break }
            result.append(event); bytes += data.count + 1
        }
        return Array(result.reversed())
    }

    private func trim() { recent = Self.bounded(recent) }
    private func publish() {
        let visible = recent.filter { $0.scope == nil || $0.scope == currentScope }
        DispatchQueue.main.async { [weak self] in self?.events = visible }
    }

    static func export(_ events: [DiagnosticEvent]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(decoding: encoder.encode(events), as: UTF8.self)) ?? "[]"
    }
}

/// User-facing failures never expose a transport payload or internal verification detail.
enum PlayerMessage {
    static func recordFailure(_ category: String, _ error: Error, requestID: String? = nil, scope: String? = nil) {
        let value = error as NSError
        var detail = (error as? APIError).map { "HTTP \($0.status) \($0.code)" }
            ?? (error as? ForestError)?.errorDescription ?? "\(value.domain) code=\(value.code)"
        if let decoding = error as? DecodingError {
            let context: DecodingError.Context
            switch decoding {
            case .dataCorrupted(let information), .keyNotFound(_, let information),
                 .typeMismatch(_, let information), .valueNotFound(_, let information): context = information
            @unknown default: context = .init(codingPath: [], debugDescription: "")
            }
            detail += " decoding path=" + context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        DiagnosticHistory.shared.record(category, "failed: " + detail, requestID: requestID, scope: scope)
    }
    static func failure(_ error: Error, fallback: String = "This couldn’t be completed. Please try again.") -> String {
        if let error = error as? APIError {
            switch error.status {
            case 401: return "Sign in again to continue. Your saved requests are retained."
            case 409: return "This information changed. Refresh and try again."
            case 429: return "Please wait a moment, then try again."
            default: return fallback
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost:
                return "Connection interrupted. Check your connection and try again."
            default: break
            }
        }
        return fallback
    }
}
