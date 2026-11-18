import SwiftUI
import UIKit

enum MilestoneTrack: String, CaseIterable, Identifiable {
    case steps, butterfly, growth, special, event
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var timeline: Bool { self == .steps || self == .butterfly }
    var symbol: String {
        switch self {
        case .steps: return "shoeprints.fill"
        case .butterfly: return "butterfly.fill"
        case .growth: return "leaf.fill"
        case .special: return "medal.fill"
        case .event: return "calendar"
        }
    }
}

private struct MilestoneRowPositions: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
struct MilestoneTracksScreen: View {
    @ObservedObject var store: CollectionCoordinator
    @State private var selected: MilestoneTrack
    @State private var growthFilter = "All"
    @State private var visibleAnchor: String?
    @State private var restoredSelection: String?
    @State private var showsInformation = false
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var questFontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var progressFontSize: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption) private var rewardFontSize: CGFloat = 12
    init(store: CollectionCoordinator) {
        self.store = store
        _selected = State(initialValue: MilestoneTrack(rawValue: store.state.milestoneTrack ?? "steps") ?? .steps)
    }
    private var selectionKey: String { selected.rawValue + "/" + growthFilter }
    private var trackRows: [APIIntroMilestone] {
        store.milestones.filter { ($0.track ?? "steps") == selected.rawValue }
            .sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }
    private var rows: [APIIntroMilestone] {
        trackRows.filter { selected != .growth || growthFilter == "All" ||
            $0.category == growthFilter.lowercased() }
    }
    private func claimed(_ row: APIIntroMilestone) -> Bool {
        row.claimed || store.confirmedMilestoneIDs.contains(row.id)
    }
    private var nextGoal: String? { rows.first { !claimed($0) && $0.supersededBy == nil }?.id }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                selectors
                if selected == .growth {
                    Group {
                        if textSize.isAccessibilitySize {
                            growthPicker.pickerStyle(.menu)
                        } else { growthPicker.pickerStyle(.segmented) }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .background(JournalTheme.paper)
            GeometryReader { geometry in
                let layout = MilestoneQuestLayout(width: max(1, geometry.size.width - 32),
                    rows: store.milestones, questFontSize: questFontSize, progressFontSize: progressFontSize,
                    rewardFontSize: rewardFontSize, accessibility: textSize.isAccessibilitySize)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Color.clear.frame(height: 1).id("milestones.top")
                            status
                            if selected.timeline {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) {
                                        timelineTotal.fixedSize()
                                        Spacer(minLength: 0)
                                        nextGoalButton(proxy).fixedSize()
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        timelineTotal
                                        nextGoalButton(proxy)
                                    }
                                }
                            }
                            if rows.isEmpty && store.milestonesConfirmedAt != nil {
                                Text(selected == .event ? "No active event." : "No milestones available.")
                                    .foregroundStyle(JournalTheme.secondary).padding(.vertical, 24)
                            }
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 8) {
                                    eventHeader(row)
                                    MilestoneQuestRow(row: row, track: selected, layout: layout) {
                                        action(row, layout: layout)
                                    }
                                }.id(row.id)
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: MilestoneRowPositions.self,
                                            value: [row.id: geometry.frame(in: .named("milestoneScroll")).minY])
                                    })
                            }
                        }.padding(16).padding(.bottom, 20)
                    }
                    .coordinateSpace(name: "milestoneScroll")
                    .onPreferenceChange(MilestoneRowPositions.self) { positions in
                        let ids = Set(rows.map(\.id))
                        visibleAnchor = positions.filter { ids.contains($0.key) && $0.value >= -4 }
                            .min { $0.value < $1.value }?.key
                    }
                    .onChange(of: selectionKey) { _ in
                        visibleAnchor = nil
                        restoredSelection = nil
                    }
                    .task(id: [selectionKey] + rows.map(\.id)) {
                        // Cached rows can already exist on entry. Restore after layout,
                        // once per selection, rather than racing three scroll callbacks.
                        guard restoredSelection != selectionKey, !rows.isEmpty else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        let saved = store.state.milestoneScroll?[selected.rawValue]
                        let anchor = saved.flatMap { candidate in rows.contains { $0.id == candidate } ? candidate : nil }
                        proxy.scrollTo(anchor ?? "milestones.top", anchor: .top)
                        restoredSelection = selectionKey
                    }
                    .accessibilityIdentifier("milestones.list")
                }
            }
            .clipped()
        }
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
        .background(JournalPageBackground().ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showsInformation = true } label: {
                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                }.buttonStyle(.journalIcon).accessibilityLabel("Milestone information")
            }
        }
        .sheet(isPresented: $showsInformation) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        information("Activity days", "A day qualifies with at least 1,000 accepted steps or 10 eligible workout minutes. Game dates use your account’s game time zone. Seven days within 14 days do not need to be consecutive.")
                        information("Workouts", "The 5 km run and 60-active-minute workout are separate quests. One workout can complete both. If your first qualifying run is already 10 km, its Enchanted reward includes the 5 km tier. A 5 km reward earned on an earlier run remains available. Pauses and manually entered workouts do not count.")
                        information("Collection", "Butterflies count when welcomed or collected from stored visits. Discovery counts unique species; variants and duplicate copies do not add species. Earned discoveries and mature-copy progress remain after a plant is sold.")
                        information("Rewards", "All tracks progress together. You can claim an earned reward in any order. Reward packs stay unopened in Packs. If pack storage is full, open a pack and retry. Bonus gems are added to your normal step-earned gems.")
                        information("Earlier rewards", "Previously fulfilled marks a tier covered by an earlier introductory reward. Your earlier funds, purchases and claimed rewards are preserved.")
                        information("Events", "Only actions accepted during an event’s earning period count. Welcomes and actual offline collections during that period count, including older stored visitors. Each event shows a separate claim deadline.")
                    }.padding(20)
                }.background(JournalPageBackground().ignoresSafeArea())
                    .navigationTitle("Milestones").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsInformation = false }.buttonStyle(.journalQuiet)
                    } }
            }.tint(JournalTheme.action)
        }
        .onDisappear { store.rememberMilestone(track: selected.rawValue, anchor: visibleAnchor) }
    }
    private var growthPicker: some View {
        Picker("Growth quests", selection: $growthFilter) {
            ForEach(["All", "Maturity", "Discovery"], id: \.self) { Text($0) }
        }
    }
    private func information(_ title: String, _ copy: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(copy).font(.body)
        }.foregroundStyle(JournalTheme.ink)
    }
    private var selectors: some View {
        // Keep the five controls independent of a second scroll-view lifecycle.
        // A native menu preserves full-size labels when the row cannot fit.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(MilestoneTrack.allCases) { trackButton($0) }
            }.fixedSize(horizontal: true, vertical: true)
            Menu {
                ForEach(MilestoneTrack.allCases) { track in
                    Button { select(track) } label: {
                        Label(track.title, systemImage: track == selected ? "checkmark" : track.symbol)
                    }
                        .accessibilityValue(rewardReady(in: track) ? "Reward ready" : "")
                        .accessibilityAddTraits(track == selected ? [.isSelected] : [])
                        .accessibilityIdentifier("milestones.track.\(track.rawValue)")
                }
            } label: {
                HStack(spacing: 10) {
                    MilestoneTrackArtwork(track: selected)
                    Text(selected.title).font(.subheadline)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.caption)
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(JournalTheme.sage, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.journalQuiet)
                .accessibilityLabel("Milestone track")
                .accessibilityValue(selected.title)
                .accessibilityIdentifier("milestones.trackMenu")
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("milestones.tracks")
    }
    private func rewardReady(in track: MilestoneTrack) -> Bool {
        store.milestones.contains { $0.track == track.rawValue && $0.eligible && !claimed($0) }
    }
    private func select(_ track: MilestoneTrack) {
        store.rememberMilestone(track: selected.rawValue, anchor: visibleAnchor)
        selected = track
        store.rememberMilestone(track: track.rawValue)
    }
    private func trackButton(_ track: MilestoneTrack) -> some View {
        Button { select(track) } label: {
            VStack(spacing: 6) {
                MilestoneTrackArtwork(track: track)
                    .overlay(alignment: .topTrailing) {
                        if track != selected && rewardReady(in: track) {
                            Circle().fill(JournalTheme.action).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                    }
                Text(track.title).font(.subheadline).fixedSize(horizontal: true, vertical: true)
                Capsule().fill(track == selected ? JournalTheme.action : Color.clear)
                    .frame(width: 28, height: 3)
            }.padding(.vertical, 10).padding(.horizontal, 4)
                .frame(minWidth: 44, minHeight: 44)
                .background(track == selected ? JournalTheme.sage : Color.clear,
                            in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.journalQuiet)
            .accessibilityLabel(track.title)
            .accessibilityValue(rewardReady(in: track) ? "Reward ready" : "")
            .accessibilityAddTraits(track == selected ? [.isSelected] : [])
            .accessibilityIdentifier("milestones.track.\(track.rawValue)")
    }
    @ViewBuilder private var status: some View {
        if store.busy && store.milestonesConfirmedAt == nil { ProgressView("Loading milestones…") }
        if let confirmedAt = store.milestonesConfirmedAt, store.refreshFailed {
            Text("Cached milestones · \(confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(JournalTheme.secondary)
        }
        if let message = store.message, store.refreshFailed || store.recoveryLocked {
            Text(message).font(.callout).accessibilityIdentifier("collection.status")
        }
        if store.state.pending != nil && !store.busy {
            Text("Awaiting confirmation").font(.callout)
            Button("Retry saved request") { Task { await store.refresh() } }
                .buttonStyle(.journalSecondary).disabled(store.busy).frame(minHeight: 44)
        } else if store.refreshFailed {
            Button("Retry refresh") { Task { await store.refresh() } }
                .buttonStyle(.journalSecondary).disabled(store.busy).frame(minHeight: 44)
        }
    }
    @ViewBuilder private var timelineTotal: some View {
        if let total = trackRows.first(where: {
            $0.metric == (selected == .steps ? "steps" : "butterflies")
        })?.progressValue {
            Text("\(Int64(min(total, Double(Int64.max - 1024))).formatted()) \(selected == .steps ? "lifetime steps" : "butterflies welcomed")")
                .font(.caption).foregroundStyle(JournalTheme.secondary)
        }
    }
    @ViewBuilder private func nextGoalButton(_ proxy: ScrollViewProxy) -> some View {
        if let nextGoal = nextGoal {
            Button("Next unclaimed goal") { proxy.scrollTo(nextGoal, anchor: .top) }
                .font(.caption).buttonStyle(.plain).foregroundStyle(JournalTheme.action).frame(minHeight: 44)
        }
    }
    @ViewBuilder private func eventHeader(_ row: APIIntroMilestone) -> some View {
        if let name = row.eventName, rows.first(where: { $0.eventId == row.eventId })?.id == row.id {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                if let end = row.endsAt {
                    if end > Date() { (Text("Ends in ") + Text(end, style: .relative)).font(.caption) }
                    else { Text("Earning ended").font(.caption) }
                }
                if let claimUntil = row.claimUntil {
                    Text("Claim by \(claimUntil.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
            }.padding(.top, 8).accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func action(_ row: APIIntroMilestone, layout: MilestoneQuestLayout) -> some View {
        // Preserve the existing state precedence, mutation guards and claim operation.
        if store.state.pending?.milestoneID == row.id {
            MilestoneRewardBox(layout: layout) {
                VStack(spacing: 4) { ProgressView(); Text("Pending") }
            }
        } else if let superseded = row.supersededBy {
            MilestoneRewardBox(layout: layout) {
                Text(superseded == "special_run_10km" ? "Included in 10 km reward" : "Fulfilled")
            }
        } else if row.legacyMilestoneId != nil {
            MilestoneRewardBox(layout: layout) { Text("Previously fulfilled") }
        } else if claimed(row) {
            MilestoneRewardBox(layout: layout, appearance: .claimed) {
                VStack(spacing: 4) { Image(systemName: "checkmark"); Text("Claimed") }
            }
        } else if row.eligible {
            let count = row.rewardPacks?.reduce(0) { $0 + $1.quantity } ?? 0
            let full = count > (store.capacity?.packRoom ?? 0)
            Button { Task { await store.claim(row) } } label: {
                MilestoneRewardBox(layout: layout, appearance: store.canMutate && !full ? .ready : .locked) {
                    if full { Text("Pack storage full") }
                    else { MilestoneQuestRewards(row: row, layout: layout) }
                }
            }
                .buttonStyle(.plain)
                .disabled(!store.canMutate || full)
                .accessibilityLabel("Claim \(MilestoneQuestPresentation.description(row))")
                .accessibilityValue(MilestoneQuestPresentation.rewards(row) + (full ? ", Pack storage full" : ""))
                .accessibilityHint(full ? "Open a pack in Packs, then retry." : "")
                .accessibilityIdentifier("milestone.\(row.id)")
        } else if row.unavailableReason == nil, row.threshold != nil, row.progressValue != nil {
            MilestoneRewardBox(layout: layout) { MilestoneQuestRewards(row: row, layout: layout) }
        } else {
            MilestoneRewardBox(layout: layout) { Text("Unavailable") }
                .accessibilityValue(row.unavailableReason ?? "Progress unavailable")
        }
    }
}

/// Display strings only; eligibility, progress fractions and rewards stay with the existing models/store.
enum MilestoneQuestPresentation {
    static func description(_ row: APIIntroMilestone) -> String {
        row.metric == "opening" ? "Start your journey" : row.description
    }
    static func progress(_ row: APIIntroMilestone) -> (current: String, target: String)? {
        guard let threshold = row.threshold, threshold > 0, let value = row.progressValue else { return nil }
        return (Int64(min(value, Double(Int64.max - 1024))).formatted(), threshold.formatted())
    }
    static func rewards(_ row: APIIntroMilestone) -> String {
        var labels: [String] = []
        if row.rewardTokens != "0" { labels.append("\(row.rewardTokens) tokens") }
        if let gems = row.rewardGems, gems != "0" { labels.append("\(gems) gems") }
        labels += (row.rewardPacks ?? []).map {
            "\($0.quantity) \($0.displayName) \($0.quantity == 1 ? "pack" : "packs")"
        }
        return labels.joined(separator: ", ")
    }
}

/// One measurement across the page's tracks/filters, independent of a row's claim state.
/// Measure real copy at the scaled fonts instead of clipping it to a fixed line limit.
struct MilestoneQuestLayout {
    let width: CGFloat
    let questFontSize: CGFloat
    let progressFontSize: CGFloat
    let rewardFontSize: CGFloat
    let rewardIconSize: CGFloat
    let rewardWidth: CGFloat
    let rewardHeight: CGFloat
    let descriptionWidth: CGFloat
    let descriptionHeight: CGFloat
    let barHeight: CGFloat
    let twoLineProgress: Bool
    let stacked: Bool
    let contentHeight: CGFloat
    var rowHeight: CGFloat { contentHeight + 16 }

    init(width: CGFloat, rows: [APIIntroMilestone], questFontSize: CGFloat = 14,
         progressFontSize: CGFloat = 10.5, rewardFontSize: CGFloat = 12, accessibility: Bool = false) {
        self.width = width
        self.questFontSize = questFontSize
        self.progressFontSize = progressFontSize
        self.rewardFontSize = rewardFontSize
        let scale = rewardFontSize / 12
        let rewardIconSize = 22 * scale
        let amountFont = UIFont.monospacedDigitSystemFont(ofSize: rewardFontSize, weight: .semibold)
        let amounts = rows.flatMap { row in
            [row.rewardTokens, row.rewardGems ?? "0"] + (row.rewardPacks ?? []).map { $0.quantity.formatted() }
        }
        let amountWidth = amounts.map { ($0 as NSString).size(withAttributes: [.font: amountFont]).width }.max() ?? 0
        let rewardWidth = min(max(1, width - 20), max(80 * scale, ceil(amountWidth) + rewardIconSize + 20))
        let stacked = accessibility || width - 20 - 32 - 20 - rewardWidth < 120
        let descriptionWidth = max(1, width - 20 - 32 - 10 - (stacked ? 0 : rewardWidth + 10))
        func height(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
            ceil((text as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height)
        }
        let questFont = UIFont.systemFont(ofSize: questFontSize, weight: .semibold)
        let descriptionHeight = max(rows.contains { $0.unavailableReason != nil } ? 44 : 32,
            max(36 * questFontSize / 14,
                (rows.map { height(MilestoneQuestPresentation.description($0), font: questFont, width: descriptionWidth) }.max() ?? 0) + 2))
        let barWidth = stacked ? max(1, width - 20) : descriptionWidth
        let progressFont = UIFont.monospacedDigitSystemFont(ofSize: progressFontSize, weight: .semibold)
        let twoLineProgress = rows.contains { row in
            let label = MilestoneQuestPresentation.progress(row).map { "\($0.current) / \($0.target)" } ?? "Progress unavailable"
            return (label as NSString).size(withAttributes: [.font: progressFont]).width > barWidth - 16
        }
        // Even unusually large individual values may wrap; reserve the tallest label for all rows.
        let labelHeight = rows.map { row -> CGFloat in
            guard let value = MilestoneQuestPresentation.progress(row) else {
                return height("Progress unavailable", font: progressFont, width: barWidth - 16)
            }
            if twoLineProgress {
                return height(value.current, font: progressFont, width: barWidth - 16) +
                    height("/ \(value.target)", font: progressFont, width: barWidth - 16)
            }
            return height("\(value.current) / \(value.target)", font: progressFont, width: barWidth - 16)
        }.max() ?? progressFont.lineHeight
        let barHeight = max(20 * progressFontSize / 10.5, labelHeight + 6)
        let stateFont = UIFont.systemFont(ofSize: progressFontSize, weight: .semibold)
        let stateHeight = ["Included in 10 km reward", "Previously fulfilled", "Pack storage full", "Unavailable"].map {
            height($0, font: stateFont, width: rewardWidth - 16)
        }.max() ?? 0
        let amountHeight = amounts.map { height($0, font: amountFont, width: rewardWidth - rewardIconSize - 20) }.max() ?? 0
        let maxLines = rows.map { row in
            (row.rewardTokens == "0" ? 0 : 1) + (row.rewardGems == nil || row.rewardGems == "0" ? 0 : 1) +
                (row.rewardPacks?.count ?? 0)
        }.max() ?? 0
        let rewardHeight = max(72 * scale, max(stateHeight + 16,
            CGFloat(maxLines) * max(rewardIconSize, amountHeight) + CGFloat(max(0, maxLines - 1)) * 4 + 16))
        self.rewardIconSize = rewardIconSize
        self.rewardWidth = rewardWidth
        self.rewardHeight = rewardHeight
        self.descriptionWidth = descriptionWidth
        self.descriptionHeight = descriptionHeight
        self.barHeight = barHeight
        self.twoLineProgress = twoLineProgress
        self.stacked = stacked
        contentHeight = stacked ? descriptionHeight + 8 + barHeight + 8 + rewardHeight :
            max(rewardHeight, descriptionHeight + 8 + barHeight)
    }
}

struct MilestoneQuestRow<Reward: View>: View {
    let row: APIIntroMilestone
    let track: MilestoneTrack
    let layout: MilestoneQuestLayout
    @ViewBuilder var reward: () -> Reward
    @State private var showsUnavailableReason = false

    var body: some View {
        Group {
            if layout.stacked {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 10) { artwork; description }
                    MilestoneQuestProgress(row: row, layout: layout)
                    reward()
                }
            } else {
                HStack(spacing: 10) {
                    artwork
                    VStack(alignment: .leading, spacing: 8) {
                        description
                        MilestoneQuestProgress(row: row, layout: layout)
                    }.frame(width: layout.descriptionWidth)
                    reward()
                }
            }
        }
        .frame(height: layout.contentHeight)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: layout.width)
        .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(JournalTheme.vine.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("milestones.row.\(row.id)")
        .alert("Reward unavailable", isPresented: $showsUnavailableReason) {
            Button("OK", role: .cancel) { }
        } message: { Text(row.unavailableReason ?? "") }
    }
    private var description: some View {
        Text(MilestoneQuestPresentation.description(row))
            .font(.system(size: layout.questFontSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: layout.descriptionWidth, height: layout.descriptionHeight, alignment: .topLeading)
    }
    @ViewBuilder private var artwork: some View {
        if let reason = row.unavailableReason {
            Button { showsUnavailableReason = true } label: {
                MilestoneTrackArtwork(track: track, width: 32)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "info.circle.fill").font(.system(size: 12))
                            .foregroundStyle(JournalTheme.action, JournalTheme.paper)
                    }.frame(width: 44, height: 44)
            }.buttonStyle(.plain).frame(width: 32)
                .accessibilityLabel("Reward unavailable: \(reason)")
                .accessibilityHint("Show full explanation")
        } else { MilestoneTrackArtwork(track: track, width: 32) }
    }
}

struct MilestoneQuestProgress: View {
    let row: APIIntroMilestone
    let layout: MilestoneQuestLayout
    private var label: String {
        MilestoneQuestPresentation.progress(row).map { "\($0.current) / \($0.target)" } ?? "Progress unavailable"
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(JournalTheme.sage)
                if MilestoneQuestPresentation.progress(row) != nil {
                    Rectangle().fill(JournalTheme.action.opacity(0.28))
                        .frame(width: geometry.size.width * row.progressFraction)
                }
            }.clipShape(RoundedRectangle(cornerRadius: layout.barHeight / 2))
        }
        .frame(height: layout.barHeight)
        .overlay(alignment: .leading) {
            Group {
                if layout.twoLineProgress, let value = MilestoneQuestPresentation.progress(row) {
                    VStack(alignment: .leading, spacing: 0) { Text(value.current); Text("/ \(value.target)") }
                } else { Text(label) }
            }.font(.system(size: layout.progressFontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(JournalTheme.ink).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MilestoneQuestPresentation.description(row)) progress")
        .accessibilityValue(label)
        .accessibilityIdentifier("milestones.progress.\(row.id)")
    }
}

struct MilestoneRewardBox<Content: View>: View {
    enum Appearance { case locked, ready, claimed }
    let layout: MilestoneQuestLayout
    var appearance: Appearance = .locked
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .font(.system(size: layout.progressFontSize, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(width: layout.rewardWidth, height: layout.rewardHeight)
            .foregroundStyle(appearance == .ready ? JournalTheme.paper : JournalTheme.ink)
            .background(appearance == .ready ? JournalTheme.action : JournalTheme.sage,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(JournalTheme.vine,
                style: StrokeStyle(lineWidth: 1, dash: appearance == .locked ? [2, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}

private struct MilestoneQuestRewards: View {
    let row: APIIntroMilestone
    let layout: MilestoneQuestLayout
    var body: some View {
        VStack(spacing: 4) {
            if row.rewardTokens != "0" { quantity("tokens", value: row.rewardTokens) }
            if let gems = row.rewardGems, gems != "0" { quantity("gems", value: gems) }
            ForEach(row.rewardPacks ?? []) { pack in
                HStack(spacing: 4) {
                    MilestoneQuestPackIcon(packID: pack.packId, size: layout.rewardIconSize)
                    Text(pack.quantity.formatted())
                }
            }
        }.font(.system(size: layout.rewardFontSize, weight: .semibold).monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MilestoneQuestPresentation.rewards(row))
    }
    private func quantity(_ metric: String, value: String) -> some View {
        HStack(spacing: 4) {
            Group {
                if let image = QuantityArtwork.images[metric] { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: QuantityArtwork.symbol(metric)).resizable().scaledToFit().padding(2) }
            }.frame(width: layout.rewardIconSize, height: layout.rewardIconSize).accessibilityHidden(true)
            Text(value)
        }
    }
}

private struct MilestoneQuestPackIcon: View {
    let packID: String
    let size: CGFloat
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "shippingbox").resizable().scaledToFit().padding(2) }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: packID) {
                image = nil
                if let path = PresentationAssets.packPath(packID: packID, part: "sealed") {
                    image = PresentationAssets.image(path, maximumPixels: 128)
                }
            }
    }
}

private struct MilestoneTrackArtwork: View {
    let track: MilestoneTrack
    var width: CGFloat = 36
    private static let images: [String: UIImage] = Dictionary(uniqueKeysWithValues:
        MilestoneTrack.allCases.compactMap { track in
            guard let image = PresentationAssets.image("milestones/v1/\(track.rawValue)-128.png", maximumPixels: 128) else { return nil }
            return (track.rawValue, image)
        })
    var body: some View {
        Group {
            if let image = Self.images[track.rawValue] {
                Image(uiImage: image).resizable().scaledToFit()
            } else { Image(systemName: track.symbol).resizable().scaledToFit().foregroundStyle(JournalTheme.action) }
        }.frame(width: width, height: 32).accessibilityHidden(true)
    }
}

struct MilestoneRewardLabels: View {
    let tokens: String
    let gems: String?
    let packs: [APIMilestonePackReward]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if tokens != "0" { Text("\(tokens) tokens") }
            if let gems = gems, gems != "0" { Text("\(gems) gems") }
            ForEach(packs) { pack in Text("\(pack.quantity) \(pack.displayName) \(pack.quantity == 1 ? "pack" : "packs")") }
        }.font(.caption).foregroundStyle(JournalTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MilestoneReceiptRewards: View {
    let receipt: APICollectionReceipt
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tokens = receipt.tokensEarned, tokens != "0" { QuantityLabel(metric: "tokens", text: "+\(tokens) tokens") }
            if let gems = receipt.gemsEarned, gems != "0" { QuantityLabel(metric: "gems", text: "+\(gems) gems") }
            if let count = receipt.packs?.count, count > 0 { Text("\(count) unopened \(count == 1 ? "pack" : "packs") saved") }
        }
    }
}
