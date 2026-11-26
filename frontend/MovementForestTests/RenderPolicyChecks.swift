import Foundation

/// Shared by native tests and portable Swift; no Apple-framework substitutes.
enum RenderPolicyChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            count += 1
            if !condition { throw NSError(domain: "RenderPolicyChecks", code: count,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        for native in [1.0, 2.0, 3.0] {
            let scale = GardenRenderPolicy.renderScale(nativeScale: native)
            try check(abs(scale - native * 0.85) < 0.00001, "Scale relative to native display")
            try check(abs(GardenRenderPolicy.renderScale(nativeScale: native) - scale) < 0.00001, "Repeated application does not compound")
        }
        try check(abs(pow(GardenRenderPolicy.scaleMultiplier, 2) - 0.7225) < 0.00001, "3D pixel ratio")
        var policy = GardenRenderPolicy()
        policy.update(thermal: .nominal, lowPower: false, now: 0)
        try check(!policy.conservesEffects && policy.recoveryDelay(now: 0) == nil, "Normal appearance")
        policy.update(thermal: .fair, lowPower: false, now: 1)
        try check(!policy.conservesEffects, "Fair thermal state preserves normal effects")
        policy.update(thermal: .serious, lowPower: false, now: 2)
        try check(policy.conservesEffects && policy.recoveryDelay(now: 2) == nil, "Immediate pressure response")
        policy.update(thermal: .nominal, lowPower: false, now: 10)
        try check(policy.conservesEffects && policy.recoveryDelay(now: 10) == 30, "Start cooldown")
        policy.update(thermal: .nominal, lowPower: false, now: 39)
        try check(policy.conservesEffects, "No early recovery")
        policy.update(thermal: .critical, lowPower: false, now: 39.5)
        try check(policy.conservesEffects && policy.recoveryDelay(now: 39.5) == nil, "New pressure resets cooldown")
        policy.update(thermal: .fair, lowPower: false, now: 50)
        policy.update(thermal: .nominal, lowPower: false, now: 79.9)
        try check(policy.conservesEffects, "Continuous cooling required")
        policy.update(thermal: .nominal, lowPower: false, now: 80)
        try check(!policy.conservesEffects && policy.recoveryDelay(now: 80) == nil, "Recover after 30 seconds")
        policy.update(thermal: .nominal, lowPower: true, now: 81)
        try check(policy.conservesEffects, "Respect Low Power Mode")
        policy.update(thermal: .nominal, lowPower: false, now: 90)
        policy.update(thermal: .nominal, lowPower: false, now: 120)
        try check(!policy.conservesEffects, "Recover from Low Power Mode")
        return count
    }
}
