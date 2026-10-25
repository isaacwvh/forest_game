import SwiftUI

enum PackRevealStep: Equatable {
    case waiting, sealed, tearing, opened, revealing, result
    var canTear: Bool { self == .sealed }
    var canReveal: Bool { self == .opened }
    static func rarityName(_ rarity: String?) -> String {
        switch rarity?.lowercased() {
        case "common": return "Common"
        case "rare": return "Rare"
        case "epic": return "Epic"
        case "legendary": return "Legendary"
        default: return "Rarity unavailable"
        }
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
                        if showsLight {
                            Ellipse().fill(RadialGradient(colors: [rarityColour.opacity(0.85), rarityColour.opacity(0)],
                                                         center: .center, startRadius: 8, endRadius: 130))
                                .frame(width: 260, height: showsPlant ? 280 : 120)
                                .offset(y: showsPlant ? 0 : -60).accessibilityHidden(true)
                        }
                        Group {
                            Group {
                                if let image = step == .sealed || step == .waiting ? sealed : opened {
                                    Image(uiImage: image).resizable().scaledToFit()
                                } else {
                                    VStack { Image(systemName: "shippingbox.fill").font(.system(size: 100)); Text(packName) }
                                }
                            }.frame(width: 210, height: 300)
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
                        Text("\(plant.speciesId.capitalized) · \(plant.variantId.capitalized)").font(.title2.bold()).multilineTextAlignment(.center)
                        Text(PackRevealStep.rarityName(result.rarity)).font(.headline)
                        Text("Your sprout is saved in Storage. Plant it from Garden → Storage.").multilineTextAlignment(.center)
                        Button("Continue") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                            .frame(minHeight: 44).accessibilityFocused($actionFocused).accessibilityIdentifier("pack.continue")
                    } else { ProgressView().tint(.white).accessibilityLabel("Opening pack") }
                    if step != .result {
                        Button(step == .waiting ? "Return to Packs" : "Continue later") { dismiss() }
                            .frame(minHeight: 44)
                    }
                }.padding(24).foregroundStyle(.white)
            }
        }
        .task {
            if let path = PresentationAssets.packPath(packID: pack.packId, part: "sealed") { sealed = PresentationAssets.image(path) }
            if let path = PresentationAssets.packPath(packID: pack.packId, part: "opened") { opened = PresentationAssets.image(path) }
            if let path = PresentationAssets.packPath(packID: pack.packId, part: "top-strip") { strip = PresentationAssets.image(path) }
            await store.open(pack)
            guard !Task.isCancelled else { return }
            submitted = true
            acceptResult()
        }
        .onChange(of: phase) { if $0 == .background { dismiss() } }
        .onDisappear { transition?.cancel(); sealed = nil; opened = nil; strip = nil }
    }

    private func acceptResult(recovered: Bool = false) {
        guard let result = store.state.result, result.ownedPackId == pack.id, result.plant != nil else { return }
        receipt = result
        if recovered { lifted = true; torn = true; step = .result }
        else { step = .sealed }
        actionFocused = true
    }
    private func advance() {
        guard receipt != nil else { return }
        if step.canTear {
            actionFocused = false
            step = .tearing
            transition = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: reduceMotion ? 1 : 150_000_000) } catch { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.35)) { torn = true }
                do { try await Task.sleep(nanoseconds: reduceMotion ? 100_000_000 : 350_000_000) } catch { return }
                step = .opened
                actionFocused = true
            }
        } else if step.canReveal {
            actionFocused = false
            step = .revealing
            transition = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: reduceMotion ? 1 : 50_000_000) } catch { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.5)) { lifted = true }
                do { try await Task.sleep(nanoseconds: reduceMotion ? 100_000_000 : 500_000_000) } catch { return }
                step = .result
                actionFocused = true
            }
        }
    }
}
