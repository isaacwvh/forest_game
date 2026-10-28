#if DEBUG
import SwiftUI

/// Local presentation harness. No account, Health reads, network or disk journal.
@MainActor
struct RewardEffectsFixtureScreen: View {
    @StateObject private var renderSession = GardenRenderSession()
    @State private var effects = GardenEffectsCoordinator(server: "effects-fixture", user: UUID(), disk: nil)
    @State private var garden = DevelopmentScene.sprouts.garden()
    @State private var assets: BundleAssetCatalog?
    @State private var error: String?
    @State private var balance = 100
    @State private var tokenReward: ConfirmedTokenReward?
    @State private var showingRecap = false
    @State private var frozen: [APIRewardRecap] = []
    @State private var lastRecipients = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    private var motionReduced: Bool {
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--fixture-reduce-motion")
    }
    private var copies: [APIOwnedPlant] {
        garden.plants.map { plant in
            .init(plantId: plant.id, speciesId: plant.speciesId, variantId: plant.variantId,
                  growthMicroUnits: "1000000", growthStage: plant.growthStage, modelKey: "", thumbnailKey: "",
                  placement: .init(gardenId: garden.gardenId, x: Decimal(plant.x), y: Decimal(plant.y), rotationDegrees: Decimal(plant.rotationDegrees)))
        }
    }
    private var confirmedGarden: APIGarden {
        .init(gardenId: garden.gardenId, width: 10, depth: 10, coordinateUnit: "garden_unit", gardenUnitMetres: 1,
              catalogVersion: garden.catalogVersion, layoutVersion: Int64(garden.layoutVersion), stateVersion: Int64(garden.stateVersion), plants: copies)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GardenSummaryHeader(tokens: String(balance), attraction: "Fixture", stored: "12/120", canCollect: tokenReward == nil,
                    tokenReward: tokenReward, tokenRewardFinished: { if tokenReward?.id == $0 { tokenReward = nil } },
                    tokenReduceMotion: motionReduced, information: {}, collect: { reward(12) })
                if let assets = assets {
                    GardenSceneView(renderer: renderSession.renderer, garden: garden, catalog: assets,
                        motionEnabled: !motionReduced, active: phase == .active && !showingRecap, growthEffects: effects)
                } else { Text(error ?? "Loading effects fixture…") }
                HStack {
                    Button("Reward +1") { reward(1) }.disabled(tokenReward != nil)
                        .accessibilityIdentifier("effects.rewardOne")
                    Button("Reset") { reset() }.accessibilityIdentifier("effects.reset")
                }.buttonStyle(.bordered).frame(minHeight: 44)
                HStack {
                    Button("Growth recap") { recap(count: 5, advance: false) }.accessibilityIdentifier("effects.growth")
                    Button("No growth") { recap(count: 0, advance: false) }.accessibilityIdentifier("effects.zero")
                }.buttonStyle(.bordered).frame(minHeight: 44)
                HStack {
                    Button("Stage recap") { recap(count: 3, advance: true) }.accessibilityIdentifier("effects.stage")
                    Button("Water 15") { recap(count: 15, advance: false) }.accessibilityIdentifier("effects.fifteen")
                }.buttonStyle(.bordered).frame(minHeight: 44)
                Text("Last recap recipients: \(lastRecipients)").font(.caption)
                    .accessibilityIdentifier("effects.recipients").accessibilityValue(String(lastRecipients))
            }
            .navigationTitle("Reward effects fixture").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingRecap, onDismiss: {
                effects.finishRecap(frozen, garden: confirmedGarden, allowPresentation: phase == .active)
                lastRecipients = effects.targets.count
                frozen = []
            }) {
                NavigationStack {
                    List {
                        Text(frozen.flatMap { $0.payload.plants }.contains { (ExactAmount.integer($0.awardedGrowthMicroUnits) ?? 0) > 0 } ?
                             "Your growth is already saved." : "No new confirmed growth.")
                        ForEach(ActivityRecapRow.make(recaps: frozen, plants: copies)) { row in
                            VStack(alignment: .leading) {
                                Text(row.plant?.speciesId.capitalized ?? "Plant")
                                Text((ExactAmount.integer(row.water) ?? 0) > 0 ? "+\(ExactAmount.water(row.water)) water" : "No new confirmed growth")
                                if let before = row.beforeStage, let after = row.afterStage, before != after {
                                    Text("\(before.title) → \(after.title)")
                                }
                            }
                        }
                    }.navigationTitle("Garden update")
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("Continue") { showingRecap = false }.accessibilityIdentifier("effects.continue")
                        } }
                }
            }
        }
        .task { do { assets = try BundleAssetCatalog() } catch { self.error = error.localizedDescription } }
        .onChange(of: phase) { if $0 != .active { tokenReward = nil; effects.cancel() } }
        .onDisappear { effects.cancel(); renderSession.renderer.setActive(false) }
    }

    private func reward(_ amount: Int) {
        balance += amount; tokenReward = .init(id: UUID(), amount: String(amount))
    }

    private func reset() {
        effects.cancel(); effects = GardenEffectsCoordinator(server: "effects-fixture", user: UUID(), disk: nil)
        garden = DevelopmentScene.sprouts.garden(); frozen = []; tokenReward = nil; balance = 100
        lastRecipients = 0
    }

    private func recap(count: Int, advance: Bool) {
        tokenReward = nil
        effects.beginRecap()
        let before = garden
        var plants = before.plants
        var awards: [APIRewardRecap.Plant] = []
        for index in plants.indices {
            let old = plants[index].growthStage
            let eligible = index < count && (!advance || old.next != nil)
            if advance && eligible, let next = old.next { plants[index].growthStage = next }
            awards.append(.init(plantId: plants[index].id, beforeGrowthMicroUnits: "0", afterGrowthMicroUnits: eligible ? "1000000" : "0",
                awardedGrowthMicroUnits: eligible ? "1000000" : "0", beforeStage: old, afterStage: plants[index].growthStage))
        }
        frozen = [.init(recapId: UUID(), createdAt: Date(), payload: .init(kind: "activity_growth", creditIds: [],
            plants: awards, activityDays: [], resourceDeltas: [:]))]
        garden = .init(gardenId: before.gardenId, title: before.title, isSample: true, width: before.width,
            depth: before.depth, gardenUnitMetres: before.gardenUnitMetres, catalogVersion: before.catalogVersion,
            layoutVersion: before.layoutVersion, stateVersion: before.stateVersion + 1, plants: plants)
        showingRecap = true
    }
}
#endif
