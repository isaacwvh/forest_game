import SwiftUI

@MainActor
struct ProfileHostScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    var section = ProfileSection.overview
    var body: some View {
        Group {
            if let store = connection.accountSummary {
                ProfileScreen(store: store, connection: connection, catalog: catalog, section: section)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your forest profile").font(.system(.title, design: .serif))
                    Text(connection.connecting ? "Connecting to your account…" : "Sign in to view your level, gems and lifetime record.")
                        .foregroundStyle(JournalTheme.secondary)
                    if connection.connecting { ProgressView() }
                    NavigationLink("Account and sign-in") { AccountScreen(connection: connection, catalog: catalog) }
                        .buttonStyle(.journalSecondary)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .background(JournalPageBackground().ignoresSafeArea())
    }
}

@MainActor
private struct ProfileScreen: View {
    @ObservedObject var store: AccountSummaryStore
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    let section: ProfileSection
    @State private var positioned = false
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            if store.failed || store.showsSavedProgress {
                AccountSummaryNotice(store: store).padding(.horizontal, 20).padding(.vertical, 8)
                    .background(JournalTheme.sage.opacity(0.65))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let summary = store.snapshot {
                            identity(summary).id(ProfileSection.overview)
                            level(summary.progression)
                            currency(summary).id(ProfileSection.currency)
                            lifetime(summary)
                            account(summary)
                        } else if store.refreshing || !store.failed {
                            ProgressView("Loading your profile…").frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            Text("Your profile is unavailable").font(.system(.title2, design: .serif))
                            Text("Connect and retry to see your account progress.").foregroundStyle(JournalTheme.secondary)
                        }
                        if store.snapshot == nil { accountAccess }
                    }.padding(20).padding(.bottom, 24)
                }
                .task(id: store.snapshot != nil) {
                    guard store.snapshot != nil, !positioned else { return }
                    await Task.yield()
                    proxy.scrollTo(section, anchor: .top)
                    positioned = true
                }
            }
        }
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .accessibilityIdentifier("profile.page")
    }

    private func identity(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.profile.displayName).font(.system(.largeTitle, design: .serif).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("profile.displayName")
            Text("@\(summary.profile.username)").font(.subheadline).foregroundStyle(JournalTheme.secondary)
                .textSelection(.enabled).accessibilityIdentifier("profile.username")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func level(_ progression: APIAccountProgression) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalSectionHeading(title: "Account level")
            AccountLevelProgress(progression: progression)
            Text("Every 100 recorded steps earns 1 XP.").font(.footnote).foregroundStyle(JournalTheme.secondary)
        }
    }

    private func currency(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalSectionHeading(title: "Your currencies")
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) :
                AnyLayout(HStackLayout(spacing: 24))
            layout {
                currencyAmount("Tokens", metric: "tokens", value: AccountDisplay.amount(summary.wallet.tokenBalance))
                currencyAmount("Gems", metric: "gems", value: AccountDisplay.gemBalance(summary.wallet))
            }
            if summary.wallet.initialized {
                AccountGemProgress(progression: summary.progression)
                Text("Earn 1 gem for every 10,000 recorded steps, even when no plant needs water.")
                    .font(.footnote).foregroundStyle(JournalTheme.secondary)
            } else {
                Text("Your gem progress is being prepared. Sync activity to update it.")
                    .font(.footnote).foregroundStyle(JournalTheme.secondary)
            }
        }
    }

    private func currencyAmount(_ title: String, metric: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.subheadline, design: .serif)).foregroundStyle(JournalTheme.secondary)
            QuantityLabel(metric: metric, text: value).font(.title3.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(value)")
            .accessibilityIdentifier("profile.\(metric)")
    }

    private func lifetime(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            JournalSectionHeading(title: "Lifetime record").padding(.bottom, 10)
            ProfileRecordRow(title: "Recorded steps", value: AccountDisplay.amount(summary.progression.lifetimeRecordedSteps), metric: "steps")
            ProfileRecordRow(title: "Visitors hosted", value: AccountDisplay.amount(summary.wallet.hostedTotal), metric: "attraction")
            ProfileRecordRow(title: "Visitors welcomed", value: AccountDisplay.amount(summary.wallet.hostedActive), metric: "active_visitor_rate")
            ProfileRecordRow(title: "Stored visits collected", value: AccountDisplay.amount(summary.wallet.hostedOffline), metric: "offline_visitor_rate")
            ProfileRecordRow(title: "Plants grown to adulthood", value: AccountDisplay.amount(summary.progression.plantsGrownToAdulthood), metric: "water")
            ProfileRecordRow(title: "Gems earned", value: summary.wallet.initialized ? AccountDisplay.amount(summary.wallet.lifetimeGemsEarned) : "Preparing", metric: "gems")
        }
    }

    private func account(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalSectionHeading(title: "Account information")
            DetailRow(title: "Joined", value: AccountDisplay.date(summary.profile.createdAt, timezone: summary.profile.gameTimezone))
            DetailRow(title: "Game timezone", value: summary.profile.gameTimezone)
            DetailRow(title: "Last activity sync", value: summary.progression.lastSyncAt.map {
                AccountDisplay.date($0, timezone: summary.profile.gameTimezone, includesTime: true)
            } ?? "Not yet synced")
            accountAccess
        }
    }

    private var accountAccess: some View {
        NavigationLink { AccountScreen(connection: connection, catalog: catalog) } label: {
            Label("Account and sign-in", systemImage: "person.crop.circle")
        }.buttonStyle(.journalSecondary).accessibilityIdentifier("profile.accountAccess")
    }
}

private struct ProfileRecordRow: View {
    let title: String
    let value: String
    let metric: String
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            QuantityIcon(metric: metric)
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(value).monospacedDigit().fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(JournalTheme.vine.opacity(0.3)).frame(height: 1) }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(value)")
    }
}
