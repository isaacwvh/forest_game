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
    var renderer: RealityGardenRenderer? = nil
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let renderer = renderer {
            RenderedVisitorGardenOverlay(store: store, renderer: renderer, reduceMotion: reduceMotionOverride ?? reduceMotion)
        } else {
            VisitorOverlayContent(store: store, renderer: nil, artwork: .screenSpace, reduceMotion: reduceMotionOverride ?? reduceMotion)
        }
    }
}

enum VisitorArtworkState: Equatable {
    case screenSpace, loading, model, failure
    var usesFallback: Bool { self == .screenSpace || self == .failure }
}

@MainActor
private struct RenderedVisitorGardenOverlay: View {
    @ObservedObject var store: VisitorCoordinator
    @ObservedObject var renderer: RealityGardenRenderer
    let reduceMotion: Bool
    var body: some View {
        // Observe readiness here, outside GeometryReader's cached layout closure.
        let artwork: VisitorArtworkState = renderer.visitorAssetReady ? .model :
            (renderer.visitorAssetIssue == nil ? .loading : .failure)
        VisitorOverlayContent(store: store, renderer: renderer, artwork: artwork, reduceMotion: reduceMotion)
    }
}

@MainActor
private struct VisitorOverlayContent: View {
    @ObservedObject var store: VisitorCoordinator
    let renderer: RealityGardenRenderer?
    let artwork: VisitorArtworkState
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !store.eligible)) { _ in
            ZStack {
                if artwork == .loading {
                    if !store.visibleOpportunities.isEmpty {
                        ProgressView("Loading butterfly…").font(.caption)
                            .allowsHitTesting(false).accessibilityIdentifier("visitors.artworkLoading")
                    }
                } else {
                    ForEach(store.visibleOpportunities) { visitor in
                        VisitorFlightView(store: store, visitor: visitor, reduceMotion: reduceMotion, renderer: renderer, artwork: artwork)
                            .id(visitor.id)
                    }
                }
            }
        }
        #if DEBUG
        .onAppear { reportArtwork(artwork) }
        .onChange(of: artwork) { reportArtwork($0) }
        #endif
    }

    #if DEBUG
    private func reportArtwork(_ state: VisitorArtworkState) {
        for visitor in store.visibleOpportunities { VisitorVisualDiagnostics.onArtwork?(visitor.id, state) }
    }
    #endif
}

struct VisitorFlightPose: Equatable {
    let x: Double
    let y: Double
    let flap: Double
    init(elapsed: TimeInterval, remaining: TimeInterval, reduceMotion: Bool, lane: Int = 0) {
        let age = max(0, elapsed)
        let entry = 1 - pow(1 - min(age / 1.5, 1), 3)
        let exit = min(max(remaining, 0) / 1.5, 1)
        let column = Double(max(0, lane - 1) % 3), row = Double(max(0, lane - 1) / 3)
        let centreX = lane == 0 ? 0.5 : 0.22 + 0.28 * column
        let centreY = lane == 0 ? 0.36 : 0.18 + 0.13 * row
        let sway = lane == 0 ? 0.17 : 0.035
        x = reduceMotion ? centreX : (1 - entry) * -0.15 + entry * (centreX + sway * sin(age * 0.6)) + (1 - exit) * 0.7
        y = reduceMotion ? centreY : centreY + (lane == 0 ? 0.09 : 0.025) * sin(age * 0.9)
        flap = reduceMotion ? 1 : (sin(age * 9) + 1) / 2
    }
}

#if DEBUG
/// Optional native rendering test probe; no UI, logging or Release code.
@MainActor
enum VisitorVisualDiagnostics {
    static var onFrame: ((UUID, VisitorFlightPose) -> Void)?
    static var onVisibility: ((UUID, Bool) -> Void)?
    static var onArtwork: ((UUID, VisitorArtworkState) -> Void)?
}
#endif

@MainActor
private struct VisitorFlightView: View {
    @ObservedObject var store: VisitorCoordinator
    let visitor: APIVisitorOpportunity
    let reduceMotion: Bool
    var renderer: RealityGardenRenderer? = nil
    let artwork: VisitorArtworkState
    // Identity is the opportunity, so heartbeats do not restart its flight.
    @State private var appearedAt = Date()
    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30, paused: !store.eligible)) { context in
            // Compute changing frame inputs BEFORE GeometryReader. Its cached
            // layout closure must not be the only reader of the clock.
            if store.visibleOpportunities.contains(where: { $0.id == visitor.id }), let now = store.serverNow {
                let pose = VisitorFlightPose(elapsed: context.date.timeIntervalSince(appearedAt),
                                            remaining: visitor.expiresAt.timeIntervalSince(now), reduceMotion: reduceMotion,
                                            lane: min(12, max(0, visitor.lane ?? 0)))
                let projection = renderer?.projectedVisitor(visitor.id)
                let fallback = artwork.usesFallback
                GeometryReader { geometry in
                    Button { Task { await store.welcome(visitor) } } label: {
                        Group {
                            if fallback { ForestButterfly(flap: pose.flap) }
                            else { Color.clear.frame(width: 64, height: 64) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canRequestReward)
                    .position(x: projection?.x ?? max(36, min(geometry.size.width - 36, geometry.size.width * pose.x)),
                              y: projection?.y ?? max(36, min(geometry.size.height - 36, geometry.size.height * pose.y)))
                    .opacity(fallback || projection != nil ? 1 : 0)
                    .allowsHitTesting(fallback || projection != nil)
                    .accessibilityHidden(!fallback && projection == nil)
                    .accessibilityLabel("Welcome visitor")
                    .accessibilityHint("Earn \(visitor.tokens) visitor tokens after server confirmation")
                    .accessibilityIdentifier("visitors.butterfly")
                }
                #if DEBUG
                .onAppear {
                    VisitorVisualDiagnostics.onFrame?(visitor.id, pose)
                    VisitorVisualDiagnostics.onVisibility?(visitor.id, true)
                    VisitorVisualDiagnostics.onArtwork?(visitor.id, artwork)
                }
                .onDisappear { VisitorVisualDiagnostics.onVisibility?(visitor.id, false) }
                .onChange(of: pose) { VisitorVisualDiagnostics.onFrame?(visitor.id, $0) }
                .onChange(of: artwork) { VisitorVisualDiagnostics.onArtwork?(visitor.id, $0) }
                #endif
            }
        }
    }
}

/// Board-local flight; server-issued identity/time keeps motion stable across refreshes.
struct VisitorWorldPose {
    let position: SIMD3<Float>
    let heading: Float
    init(elapsed: TimeInterval, remaining: TimeInterval, lane: Int, width: Float, depth: Float,
         height: Float, reduceMotion: Bool) {
        let index = max(0, min(11, lane - 1))
        let column = Float(index % 3), row = Float(index / 3)
        let age = Float(max(0, elapsed))
        let phase = age * 0.6 + Float(index) * 1.7
        let x = width * (0.22 + column * 0.28)
        let z = depth * (0.18 + row * 0.20)
        let arrival = min(1, age / 1.5)
        let departure = 1 - min(1, Float(max(0, remaining)) / 1.5)
        position = reduceMotion ? SIMD3(x, height + row * 0.15, z) :
            SIMD3(x + sin(phase) * width * 0.055 - (1 - arrival) * width * 0.3 + departure * width * 0.3,
                  height + row * 0.15 + sin(age * 0.9 + column) * 0.15,
                  z + cos(phase) * depth * 0.055)
        heading = reduceMotion ? 0 : (arrival < 1 || departure > 0 ? -.pi / 2 : phase - .pi / 2)
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
                        Label("\(store.tokenBalance) tokens", systemImage: "sparkles")
                        Spacer()
                        Text("Stored \(value.claimableVisits)/\(value.capacity)")
                    }
                    VStack(alignment: .leading) {
                        Label("\(store.tokenBalance) visitor tokens", systemImage: "sparkles")
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
                        if let activeRate = value.activeVisitsPerHour {
                            Text("Active arrival target: \(activeRate) visitors/hour while this garden is open. Tap butterflies to welcome them.")
                        }
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
