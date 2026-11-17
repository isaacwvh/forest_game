import SwiftUI

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
    private var nextIncomplete: String? {
        rows.first { !claimed($0) && !$0.eligible && $0.supersededBy == nil }?.id
    }
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: selected.timeline ? 0 : 14) {
                        Color.clear.frame(height: 1).id("milestones.top")
                        status
                        if selected.timeline, let total = trackRows.first(where: {
                            $0.metric == (selected == .steps ? "steps" : "butterflies")
                        })?.progressValue {
                            Text("\(Int64(min(total, Double(Int64.max - 1024))).formatted()) \(selected == .steps ? "lifetime steps" : "butterflies welcomed")")
                                .font(.title3).frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                        if let nextGoal = nextGoal, selected.timeline {
                            Button("Next unclaimed goal") { proxy.scrollTo(nextGoal, anchor: .top) }
                                .buttonStyle(.journalQuiet).frame(minHeight: 44)
                        }
                        if rows.isEmpty && store.milestonesConfirmedAt != nil {
                            Text(selected == .event ? "No active event." : "No milestones available.")
                                .foregroundStyle(JournalTheme.secondary).padding(.vertical, 24)
                        }
                        ForEach(rows) { row in
                            milestone(row).id(row.id)
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
    private func milestone(_ row: APIIntroMilestone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = row.eventName, rows.first(where: { $0.eventId == row.eventId })?.id == row.id {
                Text(name).font(.headline)
                if let end = row.endsAt {
                    if end > Date() { (Text("Ends in ") + Text(end, style: .relative)).font(.caption) }
                    else { Text("Earning ended").font(.caption) }
                }
                if let claimUntil = row.claimUntil {
                    Text("Claim by \(claimUntil.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
            }
            if textSize.isAccessibilitySize {
                rewardContent(row)
                action(row)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        rewardContent(row).frame(minWidth: 180)
                        action(row).fixedSize(horizontal: true, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        rewardContent(row)
                        action(row)
                    }
                }
            }
            if !claimed(row), row.supersededBy == nil, let threshold = row.threshold,
               row.progressValue != nil, row.metric != "opening",
               !selected.timeline || row.id == nextIncomplete {
                ProgressView(value: row.progressFraction)
                    .accessibilityLabel(row.title)
                    .accessibilityValue("\(Int64(min(row.progressValue ?? 0, Double(Int64.max - 1024)))) of \(threshold)")
            }
            if let reason = row.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(JournalTheme.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(row.eligible ? JournalTheme.sage : JournalTheme.paper,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(JournalTheme.vine.opacity(0.45), lineWidth: 1))
            .padding(.leading, selected.timeline ? 28 : 0)
            .overlay(alignment: .leading) {
                if selected.timeline {
                    // The rail follows the text height; it never determines it.
                    VStack(spacing: 0) {
                        Rectangle().fill(JournalTheme.vine.opacity(0.45)).frame(width: 1)
                        Image(systemName: claimed(row) ? "checkmark.circle.fill" : row.eligible ? "circle.inset.filled" : row.id == nextIncomplete ? "record.circle" : "circle")
                            .font(.title3).foregroundStyle(JournalTheme.action)
                        Rectangle().fill(JournalTheme.vine.opacity(0.45)).frame(width: 1)
                    }.frame(width: 18).accessibilityHidden(true)
                }
            }
            .padding(.vertical, selected.timeline ? 5 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("milestones.row.\(row.id)")
    }
    private func rewardContent(_ row: APIIntroMilestone) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let pack = row.rewardPacks?.first {
                CollectionPackArtwork(packID: pack.packId, height: 44).frame(width: 36)
            } else { QuantityIcon(metric: row.rewardTokens == "0" ? "gems" : "tokens").frame(minWidth: 36) }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                MilestoneRewardLabels(tokens: row.rewardTokens, gems: row.rewardGems,
                                      packs: row.rewardPacks ?? [])
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
    }
    @ViewBuilder private func action(_ row: APIIntroMilestone) -> some View {
        if store.state.pending?.milestoneID == row.id {
            Label("Pending", systemImage: "clock").font(.caption)
        } else if let superseded = row.supersededBy {
            Text(superseded == "special_run_10km" ? "Included in 10 km reward" : "Fulfilled")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        } else if row.legacyMilestoneId != nil {
            Text("Previously fulfilled").font(.caption)
        } else if claimed(row) {
            Label("Claimed", systemImage: "checkmark").font(.caption)
        } else if row.eligible {
            let count = row.rewardPacks?.reduce(0) { $0 + $1.quantity } ?? 0
            let full = count > (store.capacity?.packRoom ?? 0)
            VStack(spacing: 4) {
                Button("Claim") { Task { await store.claim(row) } }
                    .buttonStyle(.journalPrimary).frame(minHeight: 44)
                    .disabled(!store.canMutate || full)
                    .accessibilityLabel("Claim \(row.title)")
                    .accessibilityIdentifier("milestone.\(row.id)")
                if full { Text("Pack storage full").font(.caption) }
            }
        } else if row.unavailableReason == nil, let threshold = row.threshold,
                  let progress = row.progressValue {
            Text("\(Int64(min(progress, Double(Int64.max - 1024))).formatted()) / \(threshold.formatted())")
                .font(.caption).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        } else { Text("Unavailable").font(.caption) }
    }
}

private struct MilestoneTrackArtwork: View {
    let track: MilestoneTrack
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
        }.frame(width: 36, height: 32).accessibilityHidden(true)
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
