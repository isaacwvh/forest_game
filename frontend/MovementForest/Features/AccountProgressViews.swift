import SwiftUI

/// Native progress with explicit values supplied by the account snapshot.
struct AccountProgressTrack: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        ProgressView(value: fraction, total: 1)
            .tint(JournalTheme.action)
            .background(contrast == .increased ? JournalTheme.vine : JournalTheme.sage)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
            .accessibilityHidden(true)
    }
}

struct AccountLevelProgress: View {
    let progression: APIAccountProgression
    var compact = false
    @Environment(\.dynamicTypeSize) private var textSize
    private var display: AccountProgressDisplay { AccountProgressDisplay(progression: progression) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                AnyLayout(HStackLayout(spacing: 12))
            layout {
                QuantityLabel(metric: "xp", text: display.level)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(display.xp).font(.caption).monospacedDigit()
            }
            AccountProgressTrack(fraction: display.xpFraction)
            if !compact {
                Text("\(AccountDisplay.amount(progression.totalXp)) total XP · Next: \(display.nextLevel)")
                    .font(.footnote).foregroundStyle(JournalTheme.secondary)
            }
        }.foregroundStyle(JournalTheme.ink)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Account \(display.level)")
            .accessibilityValue(compact ? "\(display.xp), towards \(display.nextLevel)" :
                "\(display.xp), towards \(display.nextLevel), \(AccountDisplay.amount(progression.totalXp)) total XP")
            .accessibilityIdentifier(compact ? "home.levelProgress" : "profile.levelProgress")
    }
}

struct AccountGemProgress: View {
    let progression: APIAccountProgression
    var compact = false
    private var display: AccountProgressDisplay { AccountProgressDisplay(progression: progression) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text("Next gem · \(display.gemSteps)").font(compact ? .caption : .subheadline).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            AccountProgressTrack(fraction: display.gemFraction)
            if !compact { Text(display.gemRemaining).font(.footnote).foregroundStyle(JournalTheme.secondary) }
        }.foregroundStyle(JournalTheme.ink)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Next gem")
            .accessibilityValue("\(display.gemSteps), \(display.gemRemaining)")
            .accessibilityIdentifier(compact ? "home.gemProgress" : "profile.gemProgress")
    }
}

@MainActor
struct AccountSummaryNotice: View {
    @ObservedObject var store: AccountSummaryStore
    var body: some View {
        if store.failed {
            HStack(alignment: .center, spacing: 12) {
                Text(store.snapshot == nil ? "Account progress couldn’t load." : "Saved progress · Refresh unavailable")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.journalQuiet).disabled(store.refreshing)
                    .accessibilityIdentifier("accountProgress.retry")
            }.foregroundStyle(JournalTheme.secondary)
        } else if store.lastConfirmed && store.snapshot != nil {
            Label("Saved progress · Values last confirmed", systemImage: "clock")
                .font(.caption).foregroundStyle(JournalTheme.secondary)
        }
    }
}

@MainActor
struct AccountCollectionWallet: View {
    @ObservedObject var account: AccountSummaryStore
    let balance: String?
    let capacity: APIInventoryCapacity?
    var showsPlants = false
    var cached = false
    var body: some View {
        CollectionWalletSummary(balance: balance, capacity: capacity, showsPlants: showsPlants,
            cached: cached || account.lastConfirmed, gems: AccountDisplay.gemBalance(account.snapshot?.wallet))
    }
}

@MainActor
struct HomeAccountHeader: View {
    @ObservedObject var store: AccountSummaryStore
    var visitors: VisitorCoordinator?
    var attraction: String? = nil
    var information: () -> Void = {}
    let openProfile: (ProfileSection) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = store.snapshot {
                Button { openProfile(.overview) } label: {
                    AccountLevelProgress(progression: snapshot.progression, compact: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).accessibilityHint("Opens your profile")
                    .accessibilityIdentifier("home.profile")
            } else if store.refreshing || !store.failed {
                ProgressView("Loading account progress…").font(.caption).frame(minHeight: 44).padding(.horizontal, 12)
            }
            if let visitors = visitors {
                VisitorSummaryHeader(store: visitors, attraction: attraction,
                    gems: AccountDisplay.gemBalance(store.snapshot?.wallet),
                    fallbackTokens: store.snapshot.map { AccountDisplay.amount($0.wallet.tokenBalance) },
                    openGems: { openProfile(.currency) }, information: information)
            } else {
                GardenSummaryHeader(tokens: store.snapshot.map { AccountDisplay.amount($0.wallet.tokenBalance) },
                    attraction: attraction, gems: AccountDisplay.gemBalance(store.snapshot?.wallet),
                    openGems: { openProfile(.currency) }, information: information, collect: {})
            }
            if store.failed || (store.lastConfirmed && store.snapshot != nil) {
                AccountSummaryNotice(store: store).padding(.horizontal, 12)
            }
        }
            .foregroundStyle(JournalTheme.ink).background(JournalTheme.paper)
            .gardenOverlayTarget().accessibilityIdentifier("home.accountProgress")
    }
}
