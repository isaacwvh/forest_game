import SwiftUI

/// One shared screen-space appearance: always tappable above camera and foliage.
/// Its flight is presentation only; the server owns identity, expiry and reward.
struct ForestButterfly: View {
    var flap: Double
    var body: some View {
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Ellipse().fill(Color.forestTint)
                    .frame(width: 23, height: 31).rotationEffect(.degrees(side * -35))
                    .offset(x: side * 12, y: -7)
                Ellipse().fill(Color.forestTint.opacity(0.85))
                    .frame(width: 18, height: 22).rotationEffect(.degrees(side * 35))
                    .offset(x: side * 10, y: 12)
            }
            Capsule().fill(Color.primary).frame(width: 5, height: 31)
        }.scaleEffect(x: 0.65 + 0.35 * flap, y: 1)
            .frame(width: 64, height: 64)
    }
}

@MainActor
struct VisitorGardenOverlay: View {
    @ObservedObject var store: VisitorCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let visitor = store.visibleOpportunity {
            VisitorFlightView(store: store, visitor: visitor, reduceMotion: reduceMotion)
                .id(visitor.id)
        }
    }
}

struct VisitorFlightPose: Equatable {
    let x: Double
    let y: Double
    let flap: Double
    init(elapsed: TimeInterval, remaining: TimeInterval, reduceMotion: Bool) {
        let age = max(0, elapsed)
        let entry = 1 - pow(1 - min(age / 1.5, 1), 3)
        let exit = min(max(remaining, 0) / 1.5, 1)
        x = reduceMotion ? 0.5 : (1 - entry) * -0.15 + entry * (0.5 + 0.17 * sin(age * 0.6)) + (1 - exit) * 0.7
        y = reduceMotion ? 0.36 : 0.36 + 0.09 * sin(age * 0.9)
        flap = reduceMotion ? 1 : (sin(age * 9) + 1) / 2
    }
}

#if DEBUG
/// Optional native rendering test probe; no UI, logging or Release code.
@MainActor
enum VisitorVisualDiagnostics {
    static var onFrame: ((UUID, VisitorFlightPose) -> Void)?
    static var onVisibility: ((UUID, Bool) -> Void)?
}
#endif

@MainActor
private struct VisitorFlightView: View {
    @ObservedObject var store: VisitorCoordinator
    let visitor: APIVisitorOpportunity
    let reduceMotion: Bool
    // Identity is the opportunity, so heartbeats do not restart its flight.
    @State private var appearedAt = Date()
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1.0 / 30)) { context in
            // Compute changing frame inputs BEFORE GeometryReader. Its cached
            // layout closure must not be the only reader of the clock.
            if store.visibleOpportunity?.id == visitor.id, let now = store.serverNow {
                let pose = VisitorFlightPose(elapsed: context.date.timeIntervalSince(appearedAt),
                                            remaining: visitor.expiresAt.timeIntervalSince(now), reduceMotion: reduceMotion)
                GeometryReader { geometry in
                    Button { Task { await store.welcome(visitor) } } label: {
                        ForestButterfly(flap: pose.flap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canRequestReward)
                    .position(x: max(36, min(geometry.size.width - 36, geometry.size.width * pose.x)),
                              y: max(36, min(geometry.size.height - 36, geometry.size.height * pose.y)))
                    .accessibilityLabel("Welcome visitor")
                    .accessibilityHint("Earn \(visitor.tokens) visitor tokens after server confirmation")
                    .accessibilityIdentifier("visitors.butterfly")
                }
                #if DEBUG
                .onAppear {
                    VisitorVisualDiagnostics.onFrame?(visitor.id, pose)
                    VisitorVisualDiagnostics.onVisibility?(visitor.id, true)
                }
                .onDisappear { VisitorVisualDiagnostics.onVisibility?(visitor.id, false) }
                .onChange(of: pose) { VisitorVisualDiagnostics.onFrame?(visitor.id, $0) }
                #endif
            }
        }
    }
}

@MainActor
struct VisitorStatusPanel: View {
    @ObservedObject var store: VisitorCoordinator
    @State private var explanation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = store.summary {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label("\(value.tokenBalance) tokens", systemImage: "sparkles")
                        Spacer()
                        Text("Stored \(value.claimableVisits)/\(value.capacity)")
                    }
                    VStack(alignment: .leading) {
                        Label("\(value.tokenBalance) visitor tokens", systemImage: "sparkles")
                        Text("Stored visits: \(value.claimableVisits) · Capacity \(value.capacity)")
                    }
                }.font(.subheadline).monospacedDigit()
                if !store.eligible {
                    Text("Active visitors paused · Stored visits accumulate while away.").font(.caption).foregroundStyle(.secondary)
                } else if value.sources.isEmpty {
                    Text("Plant a copy to attract visitors.").font(.caption)
                } else {
                    Text("Watch for a butterfly, then tap to welcome it.").font(.caption)
                }
                HStack {
                    Button("Collect stored visits") { Task { await store.claim() } }
                        .disabled(!store.canRequestReward || value.claimableVisits == "0")
                        .accessibilityIdentifier("visitors.claim")
                    Spacer(minLength: 4)
                    if let opportunity = store.visibleOpportunity {
                        Button("Welcome visitor") { Task { await store.welcome(opportunity) } }
                            .disabled(!store.canRequestReward)
                            .accessibilityIdentifier("visitors.welcome")
                    }
                }.font(.callout).frame(minHeight: 44)
                DisclosureGroup("How visitors work", isExpanded: $explanation) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Placed plants contribute \(ExactAmount.water(value.totalAttractionMicroUnits)) attraction. Higher stages attract more; stored plants contribute none.")
                        Text("Away rate: \(value.offlineVisitsPerHour) visits/hour. Only collected whole visits become tokens.")
                        if let seconds = value.secondsUntilFull {
                            Text(seconds == 0 ? "Storage is full. Earned visits stay until collected." : "About \(max(1, (seconds + 59) / 60)) minutes until full while away.")
                        } else { Text("Time to full is shown while inactive and producing visits.") }
                        Text("Hosted: \(value.hostedTotal) · Active \(value.hostedActive) · Collected \(value.hostedOffline)")
                        if value.isFixture { Text("Development rates and rewards · Balance is provisional.") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }.font(.caption)
            } else { Text("Connecting visitors…").font(.caption) }
            if store.recoveringRequest || store.confirmingReward {
                Label("Confirming saved visitor request…", systemImage: "clock").font(.caption)
            }
            if let message = store.message { Text(message).font(.caption).accessibilityIdentifier("visitors.status") }
            if !store.connected || store.recoveringRequest {
                Button("Retry visitors") { Task { await store.tick(force: true) } }
                    .disabled(store.busy || store.recoveryLocked).font(.callout).frame(minHeight: 44)
                    .accessibilityIdentifier("visitors.retry")
            }
        }
    }
}
