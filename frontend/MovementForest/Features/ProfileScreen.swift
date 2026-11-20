import SwiftUI
import UIKit

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
                            ProfileIdentityHeader(summary: summary).id(ProfileSection.overview)
                            ProfileWalletSection(summary: summary).id(ProfileSection.currency)
                            ProfileLifetimeSection(summary: summary)
                            if let benefits = summary.benefits { ProfileCapacitySection(benefits: benefits) }
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

    private func account(_ summary: APIAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            JournalSectionHeading(title: "Account")
            DisclosureGroup {
                ProfileRecordRow(title: "Joined", value: AccountDisplay.date(summary.profile.createdAt, timezone: summary.profile.gameTimezone), symbol: "calendar")
                ProfileRecordRow(title: "Game timezone", value: summary.profile.gameTimezone, symbol: "globe")
                ProfileRecordRow(title: "Last activity sync", value: summary.progression.lastSyncAt.map {
                    AccountDisplay.date($0, timezone: summary.profile.gameTimezone, includesTime: true)
                } ?? "Not yet synced", symbol: "arrow.triangle.2.circlepath")
            } label: {
                ProfileDisclosureLabel(title: "Account details")
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
        }.buttonStyle(.journalSecondary).accessibilityIdentifier("profile.accountAccess")
    }
}

/// Profile-only artwork, decoded once from existing bundled resources. The portrait
/// is shared by every account and is independent of ownership/discovery state.
enum ProfileIllustration: String, CaseIterable {
    case portrait = "oak/v1/ui/oak-sprout-standard.png"
    case tree = "oak/v1/ui/oak-adult-standard.png"
    case steps = "png-128/steps.png"
    case visitors = "milestones/v1/butterfly-128.png"
    case activeVisits = "png-128/active_visitor_rate.png"
    case storedVisits = "png-128/offline_capacity.png"
    case tokens = "png-128/tokens.png"
    case gems = "png-128/gems.png"
    case xp = "png-128/xp.png"

    static let images: [Self: UIImage] = Dictionary(uniqueKeysWithValues: allCases.compactMap { illustration in
        guard let image = PresentationAssets.image(illustration.rawValue,
            maximumPixels: illustration == .portrait ? 256 : 128) else { return nil }
        return (illustration, image)
    })

    var symbol: String {
        switch self {
        case .portrait: return "leaf.fill"
        case .tree: return "tree.fill"
        case .steps: return "figure.walk"
        case .visitors, .activeVisits: return "butterfly.fill"
        case .storedVisits: return "tray.full.fill"
        case .tokens: return "circle.fill"
        case .gems: return "diamond.fill"
        case .xp: return "star.fill"
        }
    }
}

private struct ProfileIllustrationView: View {
    let illustration: ProfileIllustration
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let image = ProfileIllustration.images[illustration] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: illustration.symbol).resizable().scaledToFit()
                    .padding(4).foregroundStyle(JournalTheme.action)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ProfileIdentityHeader: View {
    let summary: APIAccountSummary
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            let layout = textSize >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) :
                AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            layout {
                ProfileIllustrationView(illustration: .portrait, size: 60)
                    .padding(10).background(JournalTheme.sage, in: Circle())
                    .overlay { Circle().strokeBorder(JournalTheme.vine.opacity(0.5), lineWidth: 1) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.profile.displayName).font(.system(.title, design: .serif).weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("profile.displayName")
                    Text("@\(summary.profile.username)").font(.subheadline).foregroundStyle(JournalTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("profile.username")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ProfileLevelProgress(progression: summary.progression)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProfileLevelProgress: View {
    let progression: APIAccountProgression
    private var display: AccountProgressDisplay { AccountProgressDisplay(progression: progression) }
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) :
                AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 8) {
                    ProfileIllustrationView(illustration: .xp, size: 32)
                    Text(display.level).font(.system(.title3, design: .serif).weight(.semibold))
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(display.nextLevel).font(.subheadline).foregroundStyle(JournalTheme.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            ProfileExperienceBar(text: display.xp, fraction: display.xpFraction)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Account \(display.level)")
            .accessibilityValue("\(display.xp), towards \(display.nextLevel), \(AccountDisplay.amount(progression.totalXp)) total XP")
            .accessibilityIdentifier("profile.levelProgress")
    }
}

/// The label determines the bar height, including wrapped accessibility text.
/// Masking the light label to the fill keeps contrast at both progress boundaries.
private struct ProfileExperienceBar: View {
    let text: String
    let fraction: Double
    private var caption: some View {
        Text(text).font(.caption.weight(.semibold)).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.vertical, 7)
    }
    var body: some View {
        caption.foregroundStyle(JournalTheme.ink)
            .background {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        JournalTheme.sage
                        JournalTheme.action.frame(width: geometry.size.width * fraction)
                    }.clipShape(Capsule())
                }
            }
            .overlay {
                caption.foregroundStyle(JournalTheme.paper).mask {
                    GeometryReader { geometry in
                        Rectangle().frame(width: geometry.size.width * fraction)
                    }
                }
            }.accessibilityHidden(true)
    }
}

struct ProfileWalletSection: View {
    let summary: APIAccountSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalSectionHeading(title: "Wallet")
            VStack(alignment: .leading, spacing: 16) {
                ProfileAmountBand(
                    first: ProfileAmount(title: "Tokens", value: AccountDisplay.amount(summary.wallet.tokenBalance),
                        illustration: .tokens, identifier: "profile.tokens"),
                    second: ProfileAmount(title: "Gems", value: AccountDisplay.gemBalance(summary.wallet),
                        illustration: .gems, identifier: "profile.gems"))
                if summary.wallet.initialized {
                    HStack(alignment: .top, spacing: 8) {
                        ProfileIllustrationView(illustration: .gems, size: 20)
                        AccountGemProgress(progression: summary.progression)
                    }
                } else {
                    Text("Gem progress is being prepared.")
                        .font(.footnote).foregroundStyle(JournalTheme.secondary)
                }
            }.padding(14).background(JournalTheme.sage.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct ProfileCapacitySection: View {
    let benefits: APILevelBenefits
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalSectionHeading(title: "Capacity")
            ProfileAmountBand(
                first: ProfileAmount(title: "Stored visits", value: benefits.effectiveOfflineCapacity.formatted(),
                    illustration: .storedVisits, identifier: "profile.visitCapacity"),
                second: ProfileAmount(title: "Plants", value: benefits.plantLimit.formatted(),
                    illustration: .tree, identifier: "profile.plantCapacity"))
                .padding(12).background(JournalTheme.sage.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            DisclosureGroup {
                ProfileRecordRow(title: "Base stored visits", value: benefits.baseOfflineCapacity.formatted())
                if benefits.nextBaseIncrease > 0 {
                    ProfileRecordRow(title: "Next level", value: "+\(benefits.nextBaseIncrease.formatted()) stored visits",
                        symbol: "leaf.fill", highlighted: true)
                }
                if let level = benefits.nextPlantLevel, let limit = benefits.nextPlantLimit {
                    ProfileRecordRow(title: "Level \(level)", value: "\(limit.formatted()) plants",
                        symbol: "leaf.fill", highlighted: true)
                }
            } label: { ProfileDisclosureLabel(title: "Level details") }
                .accessibilityIdentifier("profile.levelDetails")
        }
    }
}

private struct ProfileAmount: View {
    let title: String
    let value: String
    let illustration: ProfileIllustration
    let identifier: String
    var body: some View {
        HStack(spacing: 8) {
            ProfileIllustrationView(illustration: illustration)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(.title2, design: .serif).weight(.semibold)).monospacedDigit()
                Text(title).font(.subheadline).foregroundStyle(JournalTheme.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(value)")
            .accessibilityIdentifier(identifier)
    }
}

/// Long balances and large text stack instead of shrinking or truncating values.
private struct ProfileAmountBand: View {
    let first: ProfileAmount
    let second: ProfileAmount
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Group {
            if textSize.isAccessibilitySize { stacked }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        first.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        Rectangle().fill(JournalTheme.vine.opacity(0.35)).frame(width: 1, height: 40)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        second.fixedSize(horizontal: true, vertical: false)
                    }
                    stacked
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 12) { first; second }
    }
}

struct ProfileLifetimeSection: View {
    let summary: APIAccountSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JournalSectionHeading(title: "Lifetime").padding(.bottom, 4)
            ProfileRecordRow(title: "Recorded steps", value: AccountDisplay.amount(summary.progression.lifetimeRecordedSteps),
                illustration: .steps, prominent: true)
            ProfileRecordRow(title: "Visitors hosted", value: AccountDisplay.amount(summary.wallet.hostedTotal),
                illustration: .visitors, prominent: true)
            ProfileRecordRow(title: "Plants grown", value: AccountDisplay.amount(summary.progression.plantsGrownToAdulthood),
                illustration: .tree, prominent: true)
                .accessibilityLabel("Plants grown to adulthood, \(AccountDisplay.amount(summary.progression.plantsGrownToAdulthood))")
            DisclosureGroup {
                ProfileRecordRow(title: "Visitors welcomed", value: AccountDisplay.amount(summary.wallet.hostedActive),
                    illustration: .activeVisits)
                ProfileRecordRow(title: "Stored visits collected", value: AccountDisplay.amount(summary.wallet.hostedOffline),
                    illustration: .storedVisits)
                ProfileRecordRow(title: "Gems earned", value: summary.wallet.initialized ? AccountDisplay.amount(summary.wallet.lifetimeGemsEarned) : "Preparing",
                    illustration: .gems)
                ProfileRecordRow(title: "Total XP", value: AccountDisplay.amount(summary.progression.totalXp), illustration: .xp)
            } label: { ProfileDisclosureLabel(title: "More statistics") }
                .padding(.top, 8).accessibilityIdentifier("profile.moreStatistics")
        }
    }
}

private struct ProfileDisclosureLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(.subheadline, design: .serif).weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .background(JournalTheme.sage.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProfileRecordRow: View {
    let title: String
    let value: String
    var illustration: ProfileIllustration? = nil
    var symbol: String? = nil
    var prominent = false
    var highlighted = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let illustration = illustration {
                ProfileIllustrationView(illustration: illustration, size: prominent ? 40 : 28)
            } else if let symbol = symbol {
                Image(systemName: symbol).foregroundStyle(JournalTheme.action).frame(width: 24)
                    .accessibilityHidden(true)
            }
            Group {
                if textSize.isAccessibilitySize { stacked }
                else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            label.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                            amount.fixedSize(horizontal: true, vertical: false)
                        }
                        stacked
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, highlighted ? 8 : 0).padding(.vertical, prominent ? 10 : 8)
            .background(highlighted ? JournalTheme.sage.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if !highlighted {
                    Rectangle().fill(JournalTheme.vine.opacity(0.2)).frame(height: 0.5).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(value)")
    }
    private var label: some View {
        Text(title).font(.subheadline).foregroundStyle(JournalTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var amount: some View {
        Text(value).font(prominent ? .system(.title3, design: .serif).weight(.semibold) : .subheadline.weight(.medium))
            .monospacedDigit().fixedSize(horizontal: false, vertical: true)
    }
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) { label; amount }
    }
}
