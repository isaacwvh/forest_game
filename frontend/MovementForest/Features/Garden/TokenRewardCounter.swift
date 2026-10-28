import SwiftUI
import UIKit

/// Fixed geometry: the transient amount never changes the header or scene bounds.
struct TokenRewardCounter: View {
    let balance: String
    var reward: ConfirmedTokenReward?
    var finished: (UUID) -> Void = { _ in }
    var reduceMotionOverride = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var sweep: CGFloat = -1
    @State private var fading = false
    @ScaledMetric(relativeTo: .subheadline) private var rewardSpace: CGFloat = 22
    private var motionReduced: Bool { reduceMotion || reduceMotionOverride }

    private var counter: some View {
        QuantityLabel(metric: "tokens", text: balance).font(.subheadline).monospacedDigit()
    }

    var body: some View {
        counter
            .overlay {
                if reward != nil {
                    if motionReduced {
                        Color.white.opacity(fading ? 0 : 0.35).mask(counter)
                    } else {
                        GeometryReader { geometry in
                            LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(20, geometry.size.width * 0.5))
                                .offset(x: sweep * geometry.size.width)
                        }.mask(counter)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let reward = reward {
                    Text("+\(reward.amount)").font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Color.forestTint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(uiColor: .systemBackground).opacity(reduceTransparency ? 1 : 0.94), in: Capsule())
                        .fixedSize().offset(y: motionReduced ? rewardSpace : (fading ? rewardSpace * 0.6 : rewardSpace))
                        .opacity(fading ? 0 : 1)
                        .accessibilityIdentifier("visitors.tokenReward")
                }
            }
            .padding(.bottom, rewardSpace)
            .allowsHitTesting(false).accessibilityHidden(true)
            .task(id: reward?.id) {
                sweep = -1; fading = false
                guard let reward = reward else { return }
                do {
                    // Let a queued reward reset its sweep before animating again.
                    try await Task.sleep(nanoseconds: 20_000_000)
                    let unit = reward.amount == "1" ? "visitor token" : "visitor tokens"
                    UIAccessibility.post(notification: .announcement, argument: "Received \(reward.amount) \(unit)")
                    withAnimation(.easeOut(duration: motionReduced ? 0 : 0.55)) { sweep = 1.3 }
                    try await Task.sleep(nanoseconds: 300_000_000)
                    withAnimation(.easeOut(duration: motionReduced ? 0.35 : 0.75)) { fading = true }
                    try await Task.sleep(nanoseconds: 800_000_000)
                    try Task.checkCancellation()
                    finished(reward.id)
                } catch { return }
            }
    }
}
