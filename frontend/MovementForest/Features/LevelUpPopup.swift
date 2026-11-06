import SwiftUI

struct LevelUpPopup: View {
    let notice: APILevelUpNotice
    let dismiss: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.2).ignoresSafeArea().accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    card(scrolling: false).fixedSize(horizontal: false, vertical: true)
                    card(scrolling: true)
                }.frame(width: max(0, min(360, geometry.size.width - 32)))
                    .frame(maxHeight: max(0, geometry.size.height - 32))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onAppear { headingFocused = true }
    }

    private func card(scrolling: Bool) -> some View {
        VStack(spacing: 16) {
            if scrolling { ScrollView { details } }
            else { details }
            Button("Continue", action: dismiss).buttonStyle(.journalPrimary)
                .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("levelUp.continue")
        }.padding(22)
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(JournalTheme.vine, lineWidth: 1))
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("levelUp.popup")
    }

    private var details: some View {
        VStack(spacing: 16) {
            QuantityIcon(metric: "xp")
            Text("Level up!").font(.system(.title2, design: .serif).weight(.semibold))
                .accessibilityFocused($headingFocused)
            Text("Level \(notice.fromLevel) → \(notice.toLevel)")
                .font(.system(.title, design: .serif).weight(.semibold)).monospacedDigit()
                .accessibilityLabel("Level \(notice.fromLevel) to level \(notice.toLevel)")
                .accessibilityIdentifier("levelUp.levels")
            if notice.baseOfflineAfter > notice.baseOfflineBefore {
                benefit("Base offline capacity", id: "levelUp.offlineBenefit", metric: "offline_capacity",
                    gain: notice.baseOfflineAfter - notice.baseOfflineBefore, total: notice.baseOfflineAfter)
                if notice.effectiveOfflineAfter != notice.baseOfflineAfter {
                    Text("With skills at level-up: \(notice.effectiveOfflineAfter.formatted())")
                        .font(.footnote).foregroundStyle(JournalTheme.secondary)
                }
            }
            if notice.plantLimitAfter > notice.plantLimitBefore {
                benefit("Plant capacity", id: "levelUp.plantBenefit", metric: nil,
                    gain: notice.plantLimitAfter - notice.plantLimitBefore, total: notice.plantLimitAfter)
            }
        }.frame(maxWidth: .infinity)
    }

    private func benefit(_ title: String, id: String, metric: String?, gain: Int, total: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let metric = metric { QuantityIcon(metric: metric) }
            else { Image(systemName: "leaf").frame(width: 24).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline)
                Text("+\(gain.formatted()) → \(total.formatted()) total")
                    .font(.headline).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }
}
