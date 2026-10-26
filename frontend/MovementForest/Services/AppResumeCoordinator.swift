import Foundation
import Combine
import os

/// Monotonic elapsed time that continues while the phone sleeps (iOS 16+).
enum LifecycleClock {
    private static let clock = ContinuousClock()
    private static let origin = clock.now
    static var elapsed: TimeInterval {
        let duration = origin.duration(to: clock.now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

/// Development-only lifecycle events. Never pass tokens, Health payloads or names.
enum LifecycleDiagnostics {
    private static let logger = Logger(subsystem: "MovementForest", category: "Lifecycle")
    static func event(_ message: String) {
        #if DEBUG
        logger.debug("\(LifecycleClock.elapsed, privacy: .public) \(message, privacy: .public)")
        #endif
    }
}

/// One foreground waiter per connection and genuine return. The sync coordinator
/// owns durable work; cancelling this waiter never cancels or rewrites its journal.
@MainActor
final class AppResumeCoordinator: ObservableObject {
    private var foreground = false
    private var needsResume = true
    private var handledSyncID: UUID?
    private var operation: Task<Bool, Never>?
    private var connectionOperation: Task<Void, Never>?
    private var attemptedConnection = false

    func activate() {
        guard !foreground || needsResume else { return }
        foreground = true
        if needsResume {
            operation?.cancel(); operation = nil; handledSyncID = nil
            connectionOperation?.cancel(); connectionOperation = nil; attemptedConnection = false
            needsResume = false
        }
        LifecycleDiagnostics.event("scene active")
    }

    func inactive() {
        guard foreground else { return }
        foreground = false
        // Inactivity alone does not earn another pass on reactivation.
        LifecycleDiagnostics.event("scene inactive")
    }

    func background() {
        inactive(); operation?.cancel(); connectionOperation?.cancel(); needsResume = true
        LifecycleDiagnostics.event("scene background")
    }

    func resetConnection() {
        operation?.cancel(); operation = nil; handledSyncID = nil
    }

    func connectIfNeeded(_ connect: @escaping @MainActor () async -> Void) {
        guard foreground, !attemptedConnection else { return }
        attemptedConnection = true
        connectionOperation = Task { if !Task.isCancelled { await connect() } }
    }

    func reconciliation(for sync: ActivitySyncCoordinator) -> Task<Bool, Never>? {
        guard foreground else { return nil }
        if handledSyncID == sync.id { return operation }
        resetConnection(); handledSyncID = sync.id
        operation = Task {
            guard !Task.isCancelled else { return false }
            return await sync.synchronize()
        }
        LifecycleDiagnostics.event("resume requested sync=\(sync.id)")
        return operation
    }
}
