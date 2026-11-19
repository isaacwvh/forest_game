import SwiftUI
import UIKit

@MainActor
struct ExpeditionHostScreen: View {
    @ObservedObject var connection: GardenConnection
    var body: some View {
        Group {
            if let coordinator = connection.expeditions {
                ExpeditionScreen(store: coordinator).id(coordinator.id)
                    .onChange(of: connection.collection?.economyVersion) { _ in Task { await coordinator.refresh() } }
                    .onChange(of: connection.editor?.confirmed?.stateVersion) { _ in Task { await coordinator.refresh() } }
            } else {
                Text("Connect your account in Settings to see expeditions.")
                    .foregroundStyle(JournalTheme.secondary).padding()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Expedition").navigationBarTitleDisplayMode(.inline)
            .background(JournalPageBackground().ignoresSafeArea())
    }
}

@MainActor
struct ExpeditionScreen: View {
    @ObservedObject var store: ExpeditionCoordinator
    @State private var selectedQuest: String?
    @State private var selectedRun: ExpeditionRun?
    @State private var milestone: Int?
    @State private var archive = false
    @State private var popupContentHeight: CGFloat = 220
    @AccessibilityFocusState private var focusedQuest: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var run: ExpeditionRun? {
        if let selected = selectedRun { return store.archived.first(where: { $0.id == selected.id }) ?? selected }
        return store.status?.current
    }
    private var popup: Bool { selectedQuest != nil || milestone != nil }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let run = run {
                        header(run)
                        if store.cached { Text("Last confirmed expedition. Connect to collect rewards.").font(.caption).foregroundStyle(JournalTheme.secondary) }
                        if store.recovering { Label("Recovering expedition activity…", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
                        if let message = store.message { Text(message).font(.callout).foregroundStyle(JournalTheme.secondary) }
                        if store.pendingClaim {
                            Button("Retry saved reward claim") { Task { await store.retryClaim() } }.buttonStyle(.journalSecondary)
                        }
                        puzzle(run)
                        Text("Tap a piece to see its quest. Collect its reward to restore its colour.")
                            .font(.caption).foregroundStyle(JournalTheme.secondary)
                        finalReward(run)
                        if store.status?.previous.isEmpty == false, selectedRun == nil {
                            Text("Earlier expedition activity can still sync during its seven-day grace period. Earned rewards remain claimable.")
                                .font(.caption).foregroundStyle(JournalTheme.secondary)
                        }
                    } else if store.busy { ProgressView("Loading expedition…").frame(maxWidth: .infinity) }
                    else {
                        Text(store.status == nil ? "Expedition unavailable." : "No expedition is scheduled yet.").font(.headline)
                        if let message = store.message { Text(message).foregroundStyle(JournalTheme.secondary) }
                    }
                    HStack {
                        Button("Earlier expeditions") { archive = true; Task { await store.loadArchive() } }
                        Spacer()
                        Button("Recover activity") { Task { await store.recoverEvidence(retryOlder: true) } }
                            .disabled(store.recovering || store.recoveryLocked)
                    }.font(.callout).buttonStyle(.journalQuiet)
                    if selectedRun != nil {
                        Button("Return to current expedition") { selectedRun = nil }.buttonStyle(.journalSecondary)
                    }
                }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }.accessibilityHidden(popup)
            if popup, let run = run { questPopup(run) }
        }
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
        .background(JournalPageBackground().ignoresSafeArea())
        .sheet(isPresented: $archive) {
            NavigationStack {
                List {
                    ForEach(store.archived) { old in
                        Button {
                            selectedRun = old; selectedQuest = nil; milestone = nil; archive = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(old.name).font(.headline)
                                Text("\(old.month.prefix(7)) · \(old.completedCount) of 9 completed")
                                Text("\(old.rewards.filter { !$0.claimed }.count) rewards ready").font(.caption)
                            }.foregroundStyle(JournalTheme.ink)
                        }
                    }
                    if store.archiveCursor != nil {
                        Button("Load earlier months") { Task { await store.loadArchive(more: true) } }
                    }
                }.scrollContentBackground(.hidden).background(JournalPageBackground().ignoresSafeArea())
                    .navigationTitle("Earlier expeditions")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { archive = false } } }
            }
        }
        .task {
            await store.refresh()
            await store.recoverEvidence()
            // A mounted page crosses midnight even without a foreground transition.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                if let current = store.status?.current, store.serverNow >= current.endsAt, selectedRun == nil {
                    closePopup(); await store.refresh(); await store.recoverEvidence()
                }
            }
        }
        .onChange(of: store.status?.current?.runId) { _ in if selectedRun == nil { closePopup() } }
        .accessibilityIdentifier("expedition.page")
    }
    private func header(_ run: ExpeditionRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(run.name).font(.system(.largeTitle, design: .serif).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text("\(run.month.prefix(7)) · Renews on the first at 00:00 UTC")
                .font(.caption).foregroundStyle(JournalTheme.secondary)
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let remaining = max(0, run.endsAt.timeIntervalSince(store.serverNow))
                Text(remaining > 0 ? "\(Int(ceil(remaining / 86_400))) days left" : "Expedition ended")
                    .font(.callout).foregroundStyle(JournalTheme.secondary)
            }
            ExpeditionProgressBar(current: run.completedCount, target: 9, label: "Quests completed")
            HStack(alignment: .center, spacing: 12) {
                Button { milestone = 4 } label: {
                    HStack {
                        ExpeditionRewardArtwork(reward: ExpeditionReward(itemId: "comet-basin"), size: 36)
                        Text(run.completedCount >= 4 ? "Four-quest reward" : "Complete 4 quests")
                    }
                }.buttonStyle(.journalQuiet).frame(minHeight: 44)
                Spacer(minLength: 0)
                ExpeditionRewardArtwork(reward: ExpeditionReward(itemId: "worldseed-orrery"), size: 58)
            }
            let ready = run.rewards.filter { !$0.claimed }.count
            if ready > 0 { Text("\(ready) \(ready == 1 ? "reward ready" : "rewards ready")").font(.caption).foregroundStyle(JournalTheme.action) }
        }
    }
    @ViewBuilder private func puzzle(_ run: ExpeditionRun) -> some View {
        if let image = PresentationAssets.image(run.artworkKey, maximumPixels: 1536) {
            GeometryReader { geometry in
                ZStack {
                    ForEach(run.quests.sorted { $0.piece < $1.piece }) { quest in
                        let shape = ExpeditionPieceShape(index: quest.piece)
                        Button { selectedQuest = quest.id; milestone = nil } label: {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.width)
                                .saturation(quest.claimed ? 1 : 0)
                                .clipShape(shape)
                                .overlay(shape.stroke(JournalTheme.paper.opacity(0.8), lineWidth: 1))
                                .contentShape(shape)
                        }.buttonStyle(.plain)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: quest.claimed)
                            .accessibilityLabel(quest.description)
                            .accessibilityValue("\(quest.current) of \(quest.target), \(quest.claimed ? "reward collected" : quest.completedAt != nil ? "reward ready" : "in progress")")
                            .accessibilityFocused($focusedQuest, equals: quest.id)
                            .accessibilityIdentifier("expedition.piece.\(quest.piece)")
                        if quest.completedAt != nil && !quest.claimed {
                            Image(systemName: "gift.fill").font(.callout).foregroundStyle(JournalTheme.paper)
                                .padding(8).background(JournalTheme.action, in: Circle())
                                .position(x: geometry.size.width * (CGFloat(quest.piece % 3) + 0.5) / 3,
                                          y: geometry.size.width * (CGFloat(quest.piece / 3) + 0.5) / 3)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            }.aspectRatio(1, contentMode: .fit)
        } else {
            Text("The observatory artwork is unavailable. Your quests and rewards remain accessible.").font(.callout)
            ForEach(run.quests) { quest in
                Button(quest.description) { selectedQuest = quest.id }.buttonStyle(.journalQuiet).frame(minHeight: 44)
            }
        }
    }
    private func finalReward(_ run: ExpeditionRun) -> some View {
        VStack(spacing: 10) {
            HStack { ExpeditionRewardArtwork(reward: ExpeditionReward(itemId: "worldseed-orrery"), size: 64); Text("Worldseed Orrery").font(.headline); Spacer() }
            Button { milestone = 9 } label: {
                Text(run.rewards.first { $0.rewardKey == "milestone:9" }?.claimed == true ? "Reward collected" : run.completedCount == 9 ? "Claim reward" : "Complete all 9 quests")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.journalPrimary)
        }
    }
    private func closePopup() {
        let previous = selectedQuest; selectedQuest = nil; milestone = nil
        focusedQuest = previous
    }
    private func questPopup(_ run: ExpeditionRun) -> some View {
        let quest = run.quests.first { $0.id == selectedQuest }
        let count = milestone ?? 0
        let entitlement = quest?.entitlement ?? run.rewards.first { $0.rewardKey == "milestone:\(count)" }
        let reward = quest?.reward ?? ExpeditionReward(itemId: count == 4 ? "comet-basin" : "worldseed-orrery")
        return GeometryReader { geometry in
            ZStack {
                Color.black.opacity(reduceTransparency ? 0.5 : 0.28).ignoresSafeArea()
                    .onTapGesture { closePopup() }.accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack { Spacer(); Button(action: closePopup) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .buttonStyle(.journalIcon).accessibilityLabel("Close quest") }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(quest?.description ?? "Complete \(count) quests to earn this reward.")
                                .font(.headline).fixedSize(horizontal: false, vertical: true)
                            ExpeditionProgressBar(current: quest?.current ?? min(run.completedCount, count), target: quest?.target ?? max(1, count), label: "Quest progress")
                            HStack(spacing: 6) {
                                Text(reward.quantity).font(.headline.monospacedDigit())
                                ExpeditionRewardArtwork(reward: reward, size: reward.itemId == nil ? 32 : 58)
                                Spacer()
                                if entitlement?.claimed == true { Label("Claimed", systemImage: "checkmark").font(.caption) }
                            }.padding(12).background(JournalTheme.sage, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityElement(children: .ignore).accessibilityLabel(reward.accessibilityName)
                            if let message = store.message { Text(message).font(.caption).foregroundStyle(JournalTheme.secondary) }
                        }.padding(.horizontal, 20).padding(.bottom, 16)
                            .background(GeometryReader { measured in
                                Color.clear.preference(key: ExpeditionPopupHeight.self, value: measured.size.height)
                            })
                    }.frame(height: min(popupContentHeight, max(80, geometry.size.height - 180)))
                        .onPreferenceChange(ExpeditionPopupHeight.self) { popupContentHeight = max(80, $0) }
                    Button {
                        if let entitlement = entitlement { Task { await store.claim(entitlement, run: run) } }
                    } label: {
                        Text(entitlement?.claimed == true ? "Claimed" : store.pendingClaim ? "Pending confirmation" : quest != nil ? "Collect reward" : "Claim reward")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.journalPrimary)
                        .disabled(entitlement == nil || entitlement?.claimed == true || !store.canClaim)
                        .padding(.horizontal, 20).padding(.bottom, 20)
                }
                .frame(maxWidth: min(380, geometry.size.width - 32), maxHeight: geometry.size.height - 32)
                .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(JournalTheme.vine.opacity(0.5), lineWidth: 1))
                .accessibilityAddTraits(.isModal).accessibilityIdentifier("expedition.questPopup")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ExpeditionPopupHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ExpeditionProgressBar: View {
    let current: Int
    let target: Int
    let label: String
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(JournalTheme.sage)
                Capsule().fill(JournalTheme.action.opacity(0.28))
                    .frame(width: geometry.size.width * min(1, max(0, Double(current) / Double(max(1, target)))))
                Group {
                    if textSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(current.formatted()); Text("/ \(target.formatted())")
                        }
                    } else { Text("\(current.formatted()) / \(target.formatted())") }
                }.font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(JournalTheme.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
            }
        }.frame(height: max(24, height * (textSize.isAccessibilitySize ? 2 : 1)))
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue("\(current) of \(target)")
    }
}

struct ExpeditionRewardArtwork: View {
    let reward: ExpeditionReward
    let size: CGFloat
    private var path: String? {
        if let item = reward.itemId { return "\(item)/v1/ui/\(item)-standard.png" }
        if let pack = reward.packId { return PresentationAssets.packPath(packID: pack, part: "sealed") }
        return nil
    }
    var body: some View {
        Group {
            if let path = path, let image = PresentationAssets.image(path, maximumPixels: 192) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if reward.tokens != nil, let image = QuantityArtwork.images["tokens"] {
                Image(uiImage: image).resizable().scaledToFit()
            } else if reward.gems != nil, let image = QuantityArtwork.images["gems"] {
                Image(uiImage: image).resizable().scaledToFit()
            } else { Image(systemName: reward.itemId == nil ? "shippingbox" : "gift").resizable().scaledToFit().padding(4) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Each internal edge is the exact reverse of its neighbour's edge. The same
/// organic path clips artwork, draws seams and determines the tap target.
struct ExpeditionPieceShape: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 3
        let row = index / 3, col = index % 3
        let x = rect.minX + CGFloat(col) * unit, y = rect.minY + CGFloat(row) * unit
        var path = Path(); path.move(to: CGPoint(x: x, y: y))
        func edge(_ a: CGPoint, _ b: CGPoint, _ sign: CGFloat) {
            let dx = b.x - a.x, dy = b.y - a.y
            func point(_ t: CGFloat, _ bulge: CGFloat) -> CGPoint {
                CGPoint(x: a.x + dx * t - dy * bulge * sign, y: a.y + dy * t + dx * bulge * sign)
            }
            if sign == 0 { path.addLine(to: b); return }
            path.addLine(to: point(0.35, 0))
            path.addCurve(to: point(0.42, 0.03), control1: point(0.42, 0), control2: point(0.43, -0.01))
            path.addCurve(to: point(0.5, 0.105), control1: point(0.35, 0.1), control2: point(0.43, 0.105))
            path.addCurve(to: point(0.58, 0.03), control1: point(0.57, 0.105), control2: point(0.65, 0.1))
            path.addCurve(to: point(0.65, 0), control1: point(0.57, -0.01), control2: point(0.58, 0))
            path.addLine(to: b)
        }
        func direction(_ a: Int, _ b: Int) -> CGFloat { (a + b).isMultiple(of: 2) ? 1 : -1 }
        edge(CGPoint(x: x, y: y), CGPoint(x: x + unit, y: y), row == 0 ? 0 : -direction(row - 1, col))
        edge(CGPoint(x: x + unit, y: y), CGPoint(x: x + unit, y: y + unit), col == 2 ? 0 : direction(row, col))
        edge(CGPoint(x: x + unit, y: y + unit), CGPoint(x: x, y: y + unit), row == 2 ? 0 : direction(row, col))
        edge(CGPoint(x: x, y: y + unit), CGPoint(x: x, y: y), col == 0 ? 0 : -direction(row, col - 1))
        path.closeSubpath(); return path
    }
}
