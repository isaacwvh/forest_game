import Foundation
import Combine

/// One process-wide observer and one bounded cooldown task; no polling clock.
@MainActor
final class GardenPerformanceMonitor: ObservableObject {
    static let shared = GardenPerformanceMonitor()
    @Published private(set) var conservesEffects = false
    private var policy = GardenRenderPolicy()
    private var observations: [AnyCancellable] = []
    private var recovery: Task<Void, Never>?
    private let process: ProcessInfo
    private let uptime: () -> TimeInterval

    init(process: ProcessInfo = .processInfo,
         uptime: @escaping () -> TimeInterval = { LifecycleClock.elapsed }) {
        self.process = process; self.uptime = uptime
        // Apple requires reading thermalState before registering its notification.
        _ = process.thermalState
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observations.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    deinit { recovery?.cancel() }

    private func refresh() {
        let thermal: GardenRenderPolicy.ThermalState
        switch process.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        update(thermal: thermal, lowPower: process.isLowPowerModeEnabled)
    }

    /// Also allows deterministic native testing without changing device settings.
    func update(thermal: GardenRenderPolicy.ThermalState, lowPower: Bool) {
        recovery?.cancel(); recovery = nil
        policy.update(thermal: thermal, lowPower: lowPower, now: uptime())
        if conservesEffects != policy.conservesEffects { conservesEffects = policy.conservesEffects }
        if let delay = policy.recoveryDelay(now: uptime()) {
            recovery = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.01, delay) * 1_000_000_000)) }
                catch { return }
                self?.refresh()
            }
        }
    }
}
