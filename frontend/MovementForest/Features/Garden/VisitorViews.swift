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
                    // Model taps are resolved by the ARView's existing tap recognizer
                    // against the current camera frame. An invisible SwiftUI button
                    // must not intercept orbit/pan/pinch or lag behind the artwork.
                    .allowsHitTesting(fallback)
                    .accessibilityHidden(!fallback)
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

/// ARView-local points only. Clip to the actual scene, never into adjacent panels
/// or navigation controls. A partly visible visitor keeps its visible touch area.
struct VisitorHitTarget {
    let id: UUID
    let artwork: CGRect
    let touch: CGRect

    init?(id: UUID, artwork: CGRect, viewport: CGRect) {
        guard artwork.minX.isFinite, artwork.minY.isFinite,
              artwork.width.isFinite, artwork.height.isFinite,
              artwork.width > 0, artwork.height > 0,
              artwork.intersects(viewport) else { return nil }
        self.id = id
        self.artwork = artwork
        touch = artwork.insetBy(dx: -max(0, (64 - artwork.width) / 2),
                               dy: -max(0, (64 - artwork.height) / 2)).intersection(viewport)
    }

    static func pick(at point: CGPoint, from targets: [Self]) -> UUID? {
        targets.filter { $0.touch.contains(point) }.sorted { a, b in
            // Actual artwork wins over another visitor's padded target.
            let aInside = a.artwork.contains(point), bInside = b.artwork.contains(point)
            if aInside != bInside { return aInside }
            let aDistance = hypot(a.artwork.midX - point.x, a.artwork.midY - point.y)
            let bDistance = hypot(b.artwork.midX - point.x, b.artwork.midY - point.y)
            return aDistance == bDistance ? a.id.uuidString < b.id.uuidString : aDistance < bDistance
        }.first?.id
    }

    /// A VoiceOver frame must describe visible artwork, never an occluding control.
    /// Splitting rather than taking a union avoids bridging across a popup/button.
    func accessibleRect(excluding overlays: [CGRect]) -> CGRect? {
        var pieces = [artwork.intersection(touch)]
        for overlay in overlays {
            pieces = pieces.flatMap { rect -> [CGRect] in
                let cut = rect.intersection(overlay)
                guard !cut.isNull, !cut.isEmpty else { return [rect] }
                return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                        CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                        CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)]
                    .filter { !$0.isEmpty && !$0.isNull }
            }
        }
        return pieces.filter { !$0.isEmpty && !$0.isNull }.max { $0.width * $0.height < $1.width * $1.height }
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

struct GardenSummaryHeader: View {
    var tokens: String? = nil
    var attraction: String? = nil
    var stored: String? = nil
    var storedAccessibility: String? = nil
    var canCollect = false
    var collecting = false
    let information: () -> Void
    let collect: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(spacing: 6) {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    metric("Tokens", key: "tokens", value: tokens)
                    metric("Attraction", key: "attraction", value: attraction)
                    metric("Stored visits", key: "offline_capacity", value: stored)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { infoButton; Spacer(minLength: 8); collectButton }
                    VStack(alignment: .leading, spacing: 6) { infoButton; collectButton }
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    metric("Tokens", key: "tokens", value: tokens)
                    metric("Attraction", key: "attraction", value: attraction)
                    metric("Stored visits", key: "offline_capacity", value: stored)
                }
                HStack(spacing: 6) {
                    infoButton.frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity).frame(height: 0).allowsHitTesting(false)
                        .accessibilityHidden(true)
                    collectButton.frame(maxWidth: .infinity)
                }
            }
        }.padding(.horizontal, 12).padding(.top, 8)
    }

    private func metric(_ title: String, key: String, value: String?) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            QuantityLabel(metric: key, text: value ?? "Unavailable").font(.subheadline).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: textSize.isAccessibilitySize ? .leading : .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(key == "offline_capacity" ? (storedAccessibility ?? "Stored visits, Unavailable") :
                "\(key == "tokens" ? "Visitor tokens" : title), \(value ?? "Unavailable")")
    }
    private var infoButton: some View {
        Button("Garden info", action: information).buttonStyle(GardenOutlineButtonStyle())
            .font(.callout).accessibilityIdentifier("garden.info").gardenOverlayTarget()
    }
    private var collectButton: some View {
        Button(action: collect) {
            HStack(spacing: 4) {
                if collecting { ProgressView().controlSize(.small) }
                Text("Collect")
            }
        }.buttonStyle(GardenOutlineButtonStyle()).font(.callout)
            .disabled(!canCollect).foregroundStyle(canCollect ? Color.forestTint : .secondary)
            .accessibilityLabel("Collect stored visits")
            .accessibilityValue(collecting ? "Confirming collection" : "")
            .accessibilityIdentifier("visitors.claim").gardenOverlayTarget()
    }
}

@MainActor
struct VisitorSummaryHeader: View {
    @ObservedObject var store: VisitorCoordinator
    let attraction: String?
    let information: () -> Void
    var body: some View {
        GardenSummaryHeader(tokens: store.summary == nil && store.confirmedTokenBalance == nil ? nil : store.tokenBalance,
            attraction: attraction,
            stored: store.summary.map { "\($0.claimableVisits)/\($0.capacity)" },
            storedAccessibility: store.summary.map { "\($0.claimableVisits) stored visits, capacity \($0.capacity)" },
            canCollect: store.canCollect, collecting: store.collecting, information: information,
            collect: { Task { await store.claim() } })
    }
}

@MainActor
struct VisitorRecoveryNotice: View {
    @ObservedObject var store: VisitorCoordinator
    var body: some View {
        if store.needsRecoveryNotice {
            VStack(alignment: .leading, spacing: 6) {
                if let message = store.gardenMessage {
                    Text(message).font(.caption).accessibilityIdentifier("visitors.status")
                } else if !store.connected && store.summary == nil {
                    Text("Connecting visitors…").font(.caption)
                }
                if !store.connected && store.summary != nil {
                    Text("Visitor values are last confirmed.").font(.caption)
                }
                if !store.connected || store.recoveringRequest {
                    if store.recoveryLocked {
                        Text("Sign in again through Settings → Account and sign-in. Your saved request is retained.").font(.caption)
                    } else {
                        Button("Retry visitors") { Task { await store.tick(force: true) } }
                            .disabled(store.busy).frame(minHeight: 44).accessibilityIdentifier("visitors.retry")
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(GardenOutline()).gardenOverlayTarget().padding(.horizontal, 12)
        }
    }
}

@MainActor
struct VisitorInformationSection: View {
    @ObservedObject var store: VisitorCoordinator
    var body: some View {
        Section("Visitors") {
            if let value = store.summary {
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
            } else { Text("Visitor information is unavailable. Return to Garden and retry visitors.") }
        }
    }
}
