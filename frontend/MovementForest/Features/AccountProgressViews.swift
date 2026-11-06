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
    var toolbar = false
    var showsTotal = true
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var iconSize = 24.0
    private var display: AccountProgressDisplay { AccountProgressDisplay(progression: progression) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                AnyLayout(HStackLayout(spacing: toolbar ? 6 : 12))
            layout {
                HStack(spacing: 4) {
                    QuantityIcon(metric: "xp").scaleEffect(toolbar ? 0.75 : 1)
                        .frame(width: toolbar ? iconSize * 0.75 : iconSize, height: toolbar ? iconSize * 0.75 : iconSize)
                    Text(display.level).fixedSize(horizontal: false, vertical: true)
                }.font(.system(toolbar ? .caption : .subheadline, design: .serif).weight(.semibold))
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(display.xp).font(toolbar ? .caption2 : .caption).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            AccountProgressTrack(fraction: display.xpFraction)
            if !compact && showsTotal {
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
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                AnyLayout(HStackLayout(spacing: 12))
            layout {
                Text("Next gem")
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text("\(AccountDisplay.amount(progression.stepsToNextGem)) steps left").monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }.font(compact ? .caption : .subheadline)
            AccountProgressTrack(fraction: display.gemFraction)
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
        } else if store.showsSavedProgress {
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

/// Replaces the browsing navigation chrome without changing its actions or the scene owner.
struct HomeNavigationBar<Level: View>: View {
    let openMenu: () -> Void
    let openProfile: () -> Void
    let openSettings: () -> Void
    @ViewBuilder let level: () -> Level
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                navigationButton("Open collection menu", symbol: "line.3.horizontal", identifier: "collection.menu", action: openMenu)
                if textSize.isAccessibilitySize { Spacer(minLength: 0) }
                else { level().frame(maxWidth: .infinity, minHeight: 44) }
                navigationButton("Profile", symbol: "person.crop.circle", identifier: "account.profile", action: openProfile)
                navigationButton("Settings", symbol: "gearshape", identifier: "account.settings", action: openSettings)
            }
            if textSize.isAccessibilitySize { level().padding(.horizontal, 4) }
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .background(JournalTheme.paper.ignoresSafeArea(edges: .top))
            .accessibilityIdentifier("home.navigation")
    }

    private func navigationButton(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .buttonStyle(.journalIcon).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
}

@MainActor
struct HomeLevelProgress: View {
    @ObservedObject var store: AccountSummaryStore
    let openProfile: () -> Void

    var body: some View {
        if let snapshot = store.snapshot {
            Button(action: openProfile) {
                AccountLevelProgress(progression: snapshot.progression, compact: true, toolbar: true)
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Opens your profile")
                .accessibilityIdentifier("home.profile")
        } else if store.refreshing || !store.failed {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Loading account progress")
        } else {
            Text("Progress unavailable").font(.caption).foregroundStyle(JournalTheme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
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
            if let visitors = visitors {
                VisitorSummaryHeader(store: visitors, attraction: attraction,
                    gems: AccountDisplay.gemBalance(store.snapshot?.wallet),
                    fallbackTokens: store.snapshot.map { AccountDisplay.amount($0.wallet.tokenBalance) },
                    openGems: { openProfile(.currency) }, floatingActions: true, information: information)
            } else {
                GardenSummaryHeader(tokens: store.snapshot.map { AccountDisplay.amount($0.wallet.tokenBalance) },
                    attraction: attraction, gems: AccountDisplay.gemBalance(store.snapshot?.wallet),
                    openGems: { openProfile(.currency) }, floatingActions: true, information: information, collect: {})
            }
            if store.failed || store.showsSavedProgress {
                AccountSummaryNotice(store: store).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(JournalTheme.paper).gardenOverlayTarget()
            }
        }
            .foregroundStyle(JournalTheme.ink).accessibilityIdentifier("home.accountProgress")
    }
}
