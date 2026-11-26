import Foundation

/// Rendering choices only. Never changes game time, requests, rewards or input.
struct GardenRenderPolicy {
    static let scaleMultiplier = 0.85
    static let recoverySeconds: TimeInterval = 30

    enum ThermalState: Equatable { case nominal, fair, serious, critical }
    private(set) var conservesEffects = false
    private var recoveryStarted: TimeInterval?

    static func renderScale(nativeScale: Double) -> Double {
        nativeScale * scaleMultiplier
    }

    /// Require a continuous cool interval before restoring optional GPU work.
    mutating func update(thermal: ThermalState, lowPower: Bool, now: TimeInterval) {
        if lowPower || thermal == .serious || thermal == .critical {
            conservesEffects = true
            recoveryStarted = nil
        } else if conservesEffects {
            if recoveryStarted == nil { recoveryStarted = now }
            if now - (recoveryStarted ?? now) >= Self.recoverySeconds {
                conservesEffects = false
                recoveryStarted = nil
            }
        }
    }

    func recoveryDelay(now: TimeInterval) -> TimeInterval? {
        recoveryStarted.map { max(0, Self.recoverySeconds - (now - $0)) }
    }
}
