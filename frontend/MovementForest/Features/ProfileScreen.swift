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
                    Text("Your profile").font(.system(.title, design: .serif))
                    Text(connection.connecting ? "Connecting…" : "Sign in to view your profile.")
                        .foregroundStyle(JournalTheme.secondary)
                    if connection.connecting { ProgressView() }
                    NavigationLink("Account and sign-in") { AccountScreen(connection: connection, catalog: catalog) }
                        .buttonStyle(.journalSecondary)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(JournalTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
                    VStack(alignment: .leading, spacing: 20) {
                        if let summary = store.snapshot {
                            identity(summary).id(ProfileSection.overview)
                            currency(summary).id(ProfileSection.currency)
                            if let benefits = summary.benefits { benefitsSection(benefits) }
                            lifetime(summary)
                            account(summary)
                        } else if store.refreshing || !store.failed {
                            ProgressView("Loading your profile…").frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            Text("Your profile is unavailable").font(.system(.title2, design: .serif))
                            Text("Connect and retry to see your account progress.").foregroundStyle(JournalTheme.secondary)
                        }
                        if store.snapshot == nil { accountAccess }
                    }.padding(20).padding(.bottom, 8)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.profile.displayName).font(.system(.title, design: .serif).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("profile.displayName")
                Text("@\(summary.profile.username)").font(.subheadline).foregroundStyle(JournalTheme.secondary)
                    .textSelection(.enabled).accessibilityIdentifier("profile.username")
            }
            AccountLevelProgress(progression: summary.progression, showsTotal: false)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currency(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalSectionHeading(title: "Wallet")
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) :
                AnyLayout(HStackLayout(spacing: 24))
            layout {
                currencyAmount("Tokens", metric: "tokens", value: AccountDisplay.amount(summary.wallet.tokenBalance))
                currencyAmount("Gems", metric: "gems", value: AccountDisplay.gemBalance(summary.wallet))
            }
            if summary.wallet.initialized {
                AccountGemProgress(progression: summary.progression)
            } else {
                Text("Gem progress is being prepared.")
                    .font(.footnote).foregroundStyle(JournalTheme.secondary)
            }
        }
    }

    private func benefitsSection(_ value: APILevelBenefits) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            JournalSectionHeading(title: "Capacity").padding(.bottom, 4)
            ProfileRecordRow(title: "Stored visits", value: value.effectiveOfflineCapacity.formatted())
            ProfileRecordRow(title: "Plants", value: value.plantLimit.formatted())
            DisclosureGroup {
                ProfileRecordRow(title: "Base stored visits", value: value.baseOfflineCapacity.formatted())
                if value.nextBaseIncrease > 0 {
                    ProfileRecordRow(title: "Next level", value: "+\(value.nextBaseIncrease.formatted()) stored visits")
                }
                if let level = value.nextPlantLevel, let limit = value.nextPlantLimit {
                    ProfileRecordRow(title: "Level \(level)", value: "\(limit.formatted()) plants")
                }
            } label: {
                Text("Level details").font(.subheadline).frame(minHeight: 44)
            }
            .accessibilityIdentifier("profile.levelDetails")
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
            JournalSectionHeading(title: "Lifetime").padding(.bottom, 4)
            ProfileRecordRow(title: "Recorded steps", value: AccountDisplay.amount(summary.progression.lifetimeRecordedSteps))
            ProfileRecordRow(title: "Visitors hosted", value: AccountDisplay.amount(summary.wallet.hostedTotal))
            ProfileRecordRow(title: "Plants grown", value: AccountDisplay.amount(summary.progression.plantsGrownToAdulthood))
                .accessibilityLabel("Plants grown to adulthood, \(AccountDisplay.amount(summary.progression.plantsGrownToAdulthood))")
            DisclosureGroup {
                ProfileRecordRow(title: "Visitors welcomed", value: AccountDisplay.amount(summary.wallet.hostedActive))
                ProfileRecordRow(title: "Stored visits collected", value: AccountDisplay.amount(summary.wallet.hostedOffline))
                ProfileRecordRow(title: "Gems earned", value: summary.wallet.initialized ? AccountDisplay.amount(summary.wallet.lifetimeGemsEarned) : "Preparing")
                ProfileRecordRow(title: "Total XP", value: AccountDisplay.amount(summary.progression.totalXp))
            } label: {
                Text("More statistics").font(.subheadline).frame(minHeight: 44)
            }
            .accessibilityIdentifier("profile.moreStatistics")
        }
    }

    private func account(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup {
                ProfileRecordRow(title: "Joined", value: AccountDisplay.date(summary.profile.createdAt, timezone: summary.profile.gameTimezone))
                ProfileRecordRow(title: "Game timezone", value: summary.profile.gameTimezone)
                ProfileRecordRow(title: "Last activity sync", value: summary.progression.lastSyncAt.map {
                    AccountDisplay.date($0, timezone: summary.profile.gameTimezone, includesTime: true)
                } ?? "Not yet synced")
            } label: {
                Text("Account details").font(.subheadline).frame(minHeight: 44)
            }
            .accessibilityIdentifier("profile.accountDetails")
            accountAccess
        }
    }

    private var accountAccess: some View {
        NavigationLink { AccountScreen(connection: connection, catalog: catalog) } label: {
            HStack {
                Label("Account and sign-in", systemImage: "person.crop.circle")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(JournalTheme.action).accessibilityIdentifier("profile.accountAccess")
    }
}

private struct ProfileRecordRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            Text(title).foregroundStyle(JournalTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(value).monospacedDigit().fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(textSize.isAccessibilitySize ? .leading : .trailing)
        }.font(.subheadline).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(value)")
    }
}
