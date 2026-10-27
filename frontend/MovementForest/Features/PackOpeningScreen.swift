import SwiftUI

enum PackRevealStep: Equatable {
    case waiting, sealed, tearing, opened, revealing, result
    var canTear: Bool { self == .sealed }
    var canReveal: Bool { self == .opened }
    static func rarityName(_ rarity: String?) -> String {
        PlantRarity(label: rarity)?.title ?? "Rarity unavailable"
    }
}

@MainActor
struct PackOpeningScreen: View {
    @ObservedObject var store: CollectionCoordinator
    let pack: APIOwnedPack
    let assets: any AssetCatalogProviding
    var reduceMotionOverride: Bool? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @AccessibilityFocusState private var actionFocused: Bool
    @State private var step: PackRevealStep = .waiting
    @State private var receipt: APICollectionReceipt?
    @State private var sealed: UIImage?
    @State private var opened: UIImage?
    @State private var strip: UIImage?
    @State private var transition: Task<Void, Never>?
    @State private var torn = false
    @State private var lifted = false
    @State private var submitted = false
    @State private var submissionStarted = false
    @State private var interrupted = false

    private var rarityColour: Color {
        switch receipt?.rarity?.lowercased() {
        case "common": return Color(white: 0.85)
        case "rare": return .blue
        case "epic": return .purple
        case "legendary": return Color(red: 1, green: 0.76, blue: 0.22)
        default: return .white
        }
    }
    private var packName: String { store.definitions[pack.definitionID]?.displayName ?? pack.packId.capitalized + " pack" }
    private var showsLight: Bool { [.tearing, .opened, .revealing, .result].contains(step) }
    private var showsPlant: Bool { step == .revealing || step == .result }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Text(packName).font(.title2.bold()).multilineTextAlignment(.center)
                    ZStack {
                        if showsLight && showsPlant {
                            Ellipse().fill(RadialGradient(colors: [rarityColour.opacity(0.85), rarityColour.opacity(0)],
                                                         center: .center, startRadius: 8, endRadius: 130))
                                .frame(width: 260, height: 280).accessibilityHidden(true)
                        }
                        Group {
                            Group {
                                if let image = step == .sealed || step == .waiting ? sealed : opened {
                                    Image(uiImage: image).resizable().scaledToFit()
                                } else {
                                    VStack { Image(systemName: "shippingbox.fill").font(.system(size: 100)); Text(packName) }
                                }
                            }.frame(width: 210, height: 300)
                                .overlay {
                                    if showsLight {
                                        PackMouthLight(colour: rarityColour, woodland: opened != nil)
                                            .opacity(lifted ? 0 : 1)
                                    }
                                }
                                .scaleEffect(step == .tearing && !reduceMotion ? 0.96 : 1)
                                .offset(y: lifted && !reduceMotion ? 80 : 0).opacity(lifted ? 0 : 1)
                            if let strip = strip, step == .tearing || step == .opened {
                                Image(uiImage: strip).resizable().scaledToFit().frame(width: 210, height: 300)
                                    .offset(x: torn && !reduceMotion ? 45 : 0, y: torn && !reduceMotion ? -70 : 0)
                                    .rotationEffect(.degrees(torn && !reduceMotion ? 18 : 0))
                                    .opacity(torn ? 0 : 1)
                            }
                        }
                        if showsPlant, let plant = receipt?.plant, let catalogue = store.catalogue {
                            PlantThumbnail(plant: plant.rendered(catalogue: catalogue, assets: assets), catalog: assets)
                                .frame(width: 210, height: 260)
                                .offset(y: lifted || reduceMotion ? 0 : 60).opacity(lifted ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 320)
                    .contentShape(Rectangle())
                    .onTapGesture { advance() }
                    .accessibilityHidden(true)
                    if step == .waiting {
                        if !submitted || store.busy { ProgressView("Confirming your pack…").tint(.white) }
                        else {
                            Text(store.message ?? "The opening is awaiting confirmation.")
                            if store.state.pending != nil {
                                Button("Retry saved opening") { Task { await store.refresh(); acceptResult(recovered: true) } }
                                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            } else { Text("Return to Packs to try again. No new opening will be submitted here.") }
                        }
                    } else if step == .sealed || step == .opened {
                        Button(step == .sealed ? "Tap to open" : "Tap to reveal") { advance() }
                            .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44)
                            .accessibilityFocused($actionFocused)
                            .accessibilityIdentifier(step == .sealed ? "pack.tear" : "pack.reveal")
                        if step == .opened { Text(PackRevealStep.rarityName(receipt?.rarity)).font(.headline) }
                    } else if step == .result, let result = receipt, let plant = result.plant {
                        PlantNameText("\(plant.speciesId.capitalized) · \(plant.variantId.capitalized)", rarity: result.rarity,
                            onDarkBackground: true, announcesRarity: false).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(PackRevealStep.rarityName(result.rarity)).font(.headline)
                        Text("Your sprout is saved in Storage. Plant it from Edit → Storage → plant details → Place.").multilineTextAlignment(.center)
                        Button("Continue") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                            .frame(minHeight: 44).accessibilityFocused($actionFocused).accessibilityIdentifier("pack.continue")
                    } else { ProgressView().tint(.white).accessibilityLabel("Opening pack") }
                    if step == .waiting {
                        Button("Return to Packs") { interrupt() }
                            .frame(minHeight: 44)
                    }
                }.padding(24).foregroundStyle(.white)
            }
        }
        .task {
            guard !submissionStarted, !interrupted else { return }
            submissionStarted = true
            if store.confirmedOpening(for: pack.id) != nil {
                submitted = true; acceptResult(recovered: true); return
            }
            let recovering = store.state.pending != nil
            if let path = PresentationAssets.packPath(packID: pack.packId, part: "sealed") { sealed = PresentationAssets.image(path) }
            if let path = PresentationAssets.packPath(packID: pack.packId, part: "opened") { opened = PresentationAssets.image(path) }
            if let path = PresentationAssets.packPath(packID: pack.packId, part: "top-strip") { strip = PresentationAssets.image(path) }
            await store.open(pack)
            guard !Task.isCancelled, !interrupted else { return }
            submitted = true
            acceptResult(recovered: recovering)
        }
        .onChange(of: store.state.result?.openingId) { _ in
            // A request owned by an earlier presentation may finish after this
            // screen has reattached. Its saved result must not start a ceremony.
            if submitted && step == .waiting { acceptResult(recovered: true) }
        }
        .onChange(of: phase) { if $0 == .background { interrupt() } }
        .onDisappear { interrupted = true; transition?.cancel(); sealed = nil; opened = nil; strip = nil }
    }

    private func interrupt() {
        interrupted = true; transition?.cancel(); dismiss()
    }
    private func acceptResult(recovered: Bool = false) {
        guard !interrupted, let result = store.confirmedOpening(for: pack.id) else { return }
        receipt = result
        if recovered { lifted = true; torn = true; step = .result }
        else { step = .sealed }
        actionFocused = true
    }
    private func advance() {
        guard !interrupted, phase != .background, receipt != nil else { return }
        if step.canTear {
            actionFocused = false
            step = .tearing
            transition = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: reduceMotion ? 1 : 150_000_000) } catch { return }
                guard !interrupted, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.35)) { torn = true }
                do { try await Task.sleep(nanoseconds: reduceMotion ? 100_000_000 : 350_000_000) } catch { return }
                guard !interrupted, !Task.isCancelled else { return }
                step = .opened
                actionFocused = true
            }
        } else if step.canReveal {
            actionFocused = false
            step = .revealing
            transition = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: reduceMotion ? 1 : 50_000_000) } catch { return }
                guard !interrupted, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.5)) { lifted = true }
                do { try await Task.sleep(nanoseconds: reduceMotion ? 100_000_000 : 500_000_000) } catch { return }
                guard !interrupted, !Task.isCancelled else { return }
                step = .result
                actionFocused = true
            }
        }
    }
}

/// The Woodland opening is opaque in the supplied PNG. Trace only its interior
/// aperture so the coloured light cannot wash across the opaque front artwork.
private struct PackMouth: Shape {
    var spill = false
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        return Path { path in
            path.move(to: p(0.145, 0.141))
            path.addCurve(to: p(0.855, 0.141), control1: p(0.36, 0.148), control2: p(0.67, 0.145))
            if spill {
                path.addLine(to: p(0.855, 0.07))
                path.addLine(to: p(0.145, 0.07))
            } else {
                path.addCurve(to: p(0.145, 0.141), control1: p(0.68, 0.158), control2: p(0.35, 0.158))
            }
            path.closeSubpath()
        }
    }
}

private struct PackMouthLight: View {
    let colour: Color
    let woodland: Bool
    var body: some View {
        ZStack {
            if woodland {
                PackMouth().fill(colour.opacity(0.95))
                ZStack {
                    Ellipse().fill(RadialGradient(colors: [colour.opacity(0.65), .clear],
                        center: .center, startRadius: 0, endRadius: 75))
                        .frame(width: 150, height: 44).offset(y: -108)
                }.frame(width: 200, height: 300).mask(PackMouth(spill: true))
            } else {
                // Generic wrapper has no torn-image aperture; keep a small rim glow.
                Ellipse().fill(RadialGradient(colors: [colour.opacity(0.8), .clear],
                    center: .center, startRadius: 0, endRadius: 60))
                    .frame(width: 120, height: 22).offset(y: -65)
            }
        }.frame(width: 200, height: 300).allowsHitTesting(false).accessibilityHidden(true)
    }
}
