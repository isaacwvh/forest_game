import SwiftUI

private enum GardenEditorSheet: String, Identifiable {
    case plants, storage, errors, information, details
    var id: String { rawValue }
}

@MainActor
struct ConnectedGardenScreen: View {
    @ObservedObject var store: GardenEditorStore
    let catalog: any AssetCatalogProviding
    var active: Bool
    var activitySync: ActivitySyncCoordinator? = nil
    var visitors: VisitorCoordinator? = nil
    @StateObject private var renderSession = GardenRenderSession()
    private var renderer: RealityGardenRenderer { renderSession.renderer }
    @State private var sheet: GardenEditorSheet?
    @State private var positionControlsPresented = false
    @State private var detailCopyID: UUID?
    @State private var browsingInspection: PlantInspection?
    @State private var storageInspection: PlantInspection?
    @State private var placedFromStorageInspector = false
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var textSize

    private var visitorEligible: Bool {
        active && visible && phase == .active && sheet == nil && store.canPresentVisitors
    }

    private var preview: EditorRenderPreview? {
        guard let candidate = store.candidate, var plant = store.render(candidate.plant) else { return nil }
        plant.x = NSDecimalNumber(decimal: candidate.x).doubleValue
        plant.y = NSDecimalNumber(decimal: candidate.y).doubleValue
        plant.rotationDegrees = NSDecimalNumber(decimal: candidate.rotation).doubleValue
        let radius = store.catalogue.flatMap { try? $0.radius(for: candidate.plant) }
        return EditorRenderPreview(plant: plant, radius: radius.map { Double($0) / 1000 },
                                   valid: candidate.validity == .valid, adult: candidate.kind == .plant && store.adultPreview,
                                   movable: candidate.kind == .move || candidate.kind == .plant)
    }

    var body: some View {
        Group {
            if let garden = store.rendered {
                GardenViewportLayout(compact: verticalSizeClass == .compact, editing: store.editing) {
                    GardenSceneView(renderer: renderer, garden: garden, catalog: catalog,
                                    motionEnabled: !reduceMotion, active: active && visible && phase == .active && sheet == nil,
                                    editorPreview: preview, growthEffects: store.effects, onSelect: { [weak store = store] id in
                        guard let store = store else { return }
                        guard store.candidate == nil else { return }
                        store.selectedID = id
                    }, onGroundDrag: { [weak store = store] point, event in
                        guard let store = store else { return }
                        guard store.canEdit else { return }
                        switch event {
                        case .began: break
                        case .cancelled: store.cancelCandidate()
                        case .changed, .ended:
                            if let point = point { store.updatePosition(x: point.x, y: point.y) }
                            else { store.invalidateCandidate() }
                            if event == .ended { Task { await store.releaseCandidate() } }
                        }
                    })
                    .allowsHitTesting(!positionControlsPresented)
                    .overlay {
                        if let visitors = visitors { VisitorGardenOverlay(store: visitors, renderer: renderer) }
                    }
                } status: {
                    if store.editing { statusPanel }
                    else { browsingStatus }
                } controls: {
                    if store.editing { controls }
                    else if let selected = store.selectedPlanted {
                        GardenSelectionPopup(name: name(of: selected), variant: selected.variantId.capitalized,
                            rarity: store.catalogue?.rarity(for: selected.speciesId),
                            stage: selected.growthStage.title,
                            close: { renderer.dismissSelection() },
                            details: { detailCopyID = selected.id; sheet = .details },
                            plant: store.render(selected), owned: selected, catalog: catalog)
                    }
                }
                .onPreferenceChange(GardenOverlayFrames.self) { renderer.setOverlayFrames($0) }
            } else if store.state.busy {
                ProgressView("Opening your forest…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.recoveryLocked {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(store.message ?? "Saved-edit recovery needs attention.")
                    Text("Your saved edit is retained. Sign in again through Settings → Account and sign-in to reconnect.").font(.footnote)
                }.padding()
            } else {
                RecoveryView(title: "Your garden couldn’t load", message: store.message ?? "Reconnect or refresh your garden.",
                             actionTitle: store.pending == nil ? "Refresh" : "Retry saved edit") {
                    Task { if store.pending == nil { await store.refresh() } else { await store.retryPending() } }
                }
            }
        }
        .navigationTitle("Your forest").navigationBarTitleDisplayMode(.inline)
        .preference(key: EntryPresentationBlocker.self, value: sheet != nil || (active && store.editing))
        .toolbar {
            if store.editing {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { sheet = nil; store.endEditing() } label: {
                        Label("Done", systemImage: "checkmark").frame(minHeight: 44)
                    }.accessibilityLabel("Done editing").accessibilityIdentifier("editor.done")
                }
            }
        }
        .sheet(item: secondarySheet) { item in
            NavigationStack {
                switch item {
                case .plants: plantsList
                case .storage: storageList
                case .details: EmptyView()
                case .information: gardenInformation
                case .errors:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Some plants couldn’t be displayed. Your plants and progress are saved.")
                            Button("Reload plants") {
                                sheet = nil
                                if let garden = store.rendered { renderer.retry(garden, catalog: catalog) }
                            }.frame(minHeight: 44).buttonStyle(.bordered)
                        }.padding(20)
                    }.navigationTitle("Plant artwork")
                        .background(JournalPageBackground().ignoresSafeArea())
                        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
                }
            }
        }
        .fullScreenCover(item: detailInspection) { selection in
            OwnedPlantDetailScreen(store: store, copyID: selection.id, catalog: catalog).journalModalBackground()
        }
        .onChange(of: store.selectedID) { renderer.selectedPlantID = $0 }
        .onChange(of: store.candidate?.plant.id) { if $0 == nil { positionControlsPresented = false } }
        .onChange(of: store.canEdit) { if !$0 && !store.preparingMembership { store.cancelCandidate() } }
        .onChange(of: active) { value in
            if !value { store.cancelCandidate() }
        }
        .onChange(of: phase) { value in
            if value == .background {
                if store.editing { sheet = nil; store.endEditing() }
                else { store.cancelCandidate() }
            }
            else if value != .active { store.cancelCandidate() }
        }
        .onChange(of: visitorEligible) { visitors?.setEligible($0) }
        .task(id: visitors?.id) { [visitors] in
            guard !Task.isCancelled else { return }
            renderer.setVisitors(visitors); visitors?.setEligible(visitorEligible)
        }
        .onAppear { visible = true; LiveGardenDiagnostics.shared.renderer = renderer; visitors?.setEligible(visitorEligible) }
        .onDisappear { visible = false; visitors?.setEligible(false); store.cancelCandidate(); renderer.setActive(false) }
    }

    private var browsingStatus: some View {
        VStack(spacing: 8) {
            if let visitors = visitors {
                VisitorSummaryHeader(store: visitors,
                    attraction: (store.confirmed?.totalAttractionMicroUnits).map { JournalAmount.water($0) },
                    information: { sheet = .information })
                VisitorRecoveryNotice(store: visitors)
            } else {
                GardenSummaryHeader(attraction: (store.confirmed?.totalAttractionMicroUnits).map { JournalAmount.water($0) },
                    information: { sheet = .information }, collect: {})
            }
            if store.showingCached || store.gardenMessage != nil || store.state.busy ||
                store.state == .unknown || store.state == .authenticationRequired || store.recoveryLocked ||
                !renderer.errors.isEmpty || renderer.isLoading || renderer.visitorAssetIssue != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if store.showingCached {
                        Label("Saved garden · Values last confirmed", systemImage: "wifi.slash").font(.caption)
                    }
                    if let message = store.gardenMessage {
                        Text(message).font(.callout).accessibilityIdentifier("editor.status")
                    }
                    if store.state.busy { ProgressView(store.state == .saving ? "Saving edit…" : "Refreshing garden…") }
                    if store.state == .unknown {
                        Button("Retry saved edit") { Task { await store.retryPending() } }
                            .frame(minHeight: 44).accessibilityIdentifier("editor.retry")
                    } else if store.state == .blocked && !store.recoveryLocked && store.pending == nil {
                        Button("Refresh garden") { Task { await store.refresh() } }.frame(minHeight: 44)
                    }
                    if store.state == .authenticationRequired || store.recoveryLocked {
                        Text("Sign in again through Settings → Account and sign-in. Your saved requests are retained.").font(.caption)
                    }
                    if renderer.isLoading { ProgressView("Loading plants…") }
                    if renderer.visitorAssetIssue != nil {
                        Text("Butterfly artwork is unavailable. You can still welcome visitors.").font(.caption)
                        Button("Retry visitor artwork") { renderer.setVisitors(visitors) }.frame(minHeight: 44)
                    }
                    if !renderer.errors.isEmpty {
                        Button("Some plants couldn’t load") { sheet = .errors }.frame(minHeight: 44)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(GardenOutline()).gardenOverlayTarget().padding(.horizontal, 12)
            }
        }.padding(.bottom, 8)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Editing garden", systemImage: "pencil").font(.headline)
            if store.showingCached { Label("Saved garden · Connect to refresh", systemImage: "wifi.slash").font(.caption) }
            if let candidate = store.candidate {
                Label(candidate.validity.message, systemImage: candidate.validity == .valid ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout).accessibilityIdentifier("editor.validity")
                if candidate.kind == .plant && store.adultPreview { Text("Adult preview · Clearance stays the same").font(.caption) }
            } else if let message = store.gardenMessage {
                Text(message).font(.callout).accessibilityIdentifier("editor.status")
            }
            if store.state.busy { ProgressView(store.state == .saving ? "Saving edit…" : "Refreshing garden…") }
            if store.state == .unknown {
                Button("Retry saved edit") { Task { await store.retryPending() } }
                    .frame(minHeight: 44).accessibilityIdentifier("editor.retry")
            } else if store.state == .blocked && store.pending == nil && !store.recoveryLocked {
                Button("Refresh garden") { Task { await store.refresh() } }.frame(minHeight: 44)
            } else if store.state == .authenticationRequired {
                Text("Sign in again through Settings → Account and sign-in. Your saved requests are retained.").font(.caption)
            }
            if renderer.isLoading { ProgressView("Loading plants…") }
            if renderer.visitorAssetIssue != nil {
                Text("Butterfly artwork is unavailable. You can still welcome visitors.").font(.caption)
                Button("Retry visitor artwork") { renderer.setVisitors(visitors) }.frame(minHeight: 44)
            }
            if !renderer.errors.isEmpty {
                Button("Some plants couldn’t load") { sheet = .errors }.frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 10)
            .foregroundStyle(JournalTheme.ink).background(JournalTheme.paper)
    }

    private var gardenInformation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                JournalSectionHeading(title: "Active skills")
                if let summary = store.confirmed?.skillSummary {
                    if summary.activeSkills.isEmpty { Text("No active skills").foregroundStyle(JournalTheme.secondary) }
                    ForEach(summary.activeSkills) { skill in
                        DisclosureGroup {
                            Text(skill.description).foregroundStyle(JournalTheme.secondary)
                            if let source = store.ownedCopy(skill.sourcePlantId) {
                                PlantNameText(OwnedCopyLabel.title(source.id, in: store.confirmed?.plants ?? []),
                                    rarity: store.catalogue?.rarity(for: source.speciesId), suffix: " · Fully grown source")
                                    .font(.caption).foregroundStyle(JournalTheme.secondary)
                            }
                            if skill.eligibleSourcePlantIds.count > 1 {
                                Text("\(skill.eligibleSourcePlantIds.count) sources share this bonus.").font(.caption)
                            }
                        } label: {
                            SkillSummaryLabel(skill: skill)
                        }.padding(12).background(JournalTheme.sage.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("garden.skill.\(skill.skillId)")
                    }
                    if summary.capReached {
                        DisclosureGroup("Boost cap reached") { Text(summary.caps.description).font(.footnote) }
                    }
                } else { Text("Skill information is unavailable. Refresh your garden to try again.") }
                if store.showingCached { Text("Last confirmed skills").font(.caption).foregroundStyle(JournalTheme.secondary) }
            }.padding(20)
        }.navigationTitle("Garden information")
            .background(JournalPageBackground().ignoresSafeArea()).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            if let candidate = store.candidate {
                if positionControlsPresented {
                    CandidateControlsScreen(store: store, close: { positionControlsPresented = false })
                } else if candidate.kind == .rotate {
                    GardenRotationControls(store: store)
                } else {
                    Text("\(name(of: candidate.plant)) · \(candidate.plant.variantId.capitalized)")
                        .font(.system(.subheadline, design: .serif)).padding(.top, 6)
                    editingLayout {
                        Button("Cancel") { store.cancelCandidate() }.accessibilityIdentifier("editor.cancel")
                        Button("Position…") { positionControlsPresented = true }.accessibilityIdentifier("editor.position")
                        Button("Apply") { Task { await store.releaseCandidate() } }
                            .disabled(candidate.validity != .valid || !store.canEdit).accessibilityIdentifier("editor.apply")
                    }.buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 12)
                    if candidate.kind == .plant {
                        Toggle("Show adult preview", isOn: $store.adultPreview).font(.callout).padding(.horizontal, 12)
                            .disabled(candidate.plant.growthStage == .adult).accessibilityIdentifier("editor.adult")
                    }
                }
            } else if let selected = store.selected {
                selectionPopup(selected)
            }
            if !positionControlsPresented {
                HStack(spacing: 4) {
                    GardenActionButton(title: "Select plant", symbol: "leaf", identifier: "garden.plants") { sheet = .plants }
                    GardenActionButton(title: "Storage", symbol: "tray", identifier: "editor.storage") { sheet = .storage }
                    GardenActionButton(title: "Zoom out", symbol: "minus.magnifyingglass", identifier: "editor.zoomOut") { renderer.zoom(by: 1.2) }
                    GardenActionButton(title: "Zoom in", symbol: "plus.magnifyingglass", identifier: "editor.zoomIn") { renderer.zoom(by: 0.8) }
                    GardenActionButton(title: "Reset garden view", symbol: "arrow.counterclockwise", identifier: "editor.resetView") { renderer.resetCamera() }
                }
                .padding(.horizontal, 12).background(JournalTheme.sage.opacity(0.5))
            }
        }.padding(.bottom, 4)
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action).background(JournalTheme.paper)
    }

    private func name(of plant: APIOwnedPlant) -> String {
        store.catalogue?.species.first { $0.speciesId == plant.speciesId }?.displayName ?? plant.speciesId.capitalized
    }

    @ViewBuilder private func selectionPopup(_ selected: APIOwnedPlant) -> some View {
        if selected.placement != nil {
            GardenSelectionPopup(name: name(of: selected), variant: selected.variantId.capitalized,
                rarity: store.catalogue?.rarity(for: selected.speciesId), stage: selected.growthStage.title,
                close: { renderer.dismissSelection() },
                details: { detailCopyID = selected.id; sheet = .details },
                plant: store.render(selected), owned: selected, catalog: catalog,
                move: { store.begin(selected, kind: .move) }, rotate: { store.begin(selected, kind: .rotate) },
                store: {
                    let id = selected.id
                    Task {
                        guard store.editing, store.selectedID == id else { return }
                        await store.storeSelected()
                    }
                }, editingDisabled: !store.canEdit || renderer.isLoading)
        } else {
            GardenSelectionPopup(name: name(of: selected), variant: selected.variantId.capitalized,
                rarity: store.catalogue?.rarity(for: selected.speciesId), stage: selected.growthStage.title,
                close: { renderer.dismissSelection() }, details: { detailCopyID = selected.id; sheet = .details },
                plant: store.render(selected), owned: selected, catalog: catalog)
        }
    }

    private var editingLayout: AnyLayout {
        textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
    }

    private var plantsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.confirmed?.plants.isEmpty != false { Text("No planted copies. Use Edit → Storage to place a plant.") }
                JournalGrid {
                    ForEach(store.confirmed?.plants ?? []) { plant in
                        OwnedPlantTile(plant: plant, store: store, catalog: catalog,
                            identifier: (store.editing ? "editor.plant." : "garden.plant.") + plant.id.uuidString) {
                            if store.editing {
                                store.cancelCandidate(); store.selectedID = plant.id; sheet = nil
                            } else {
                                browsingInspection = PlantInspection(id: plant.id)
                            }
                        }
                    }
                }
            }.padding(16)
        }.background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action).navigationTitle("Garden plants")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            .fullScreenCover(item: $browsingInspection) { selection in
                OwnedPlantDetailScreen(store: store, copyID: selection.id, catalog: catalog).journalModalBackground()
            }
    }

    private var secondarySheet: Binding<GardenEditorSheet?> {
        Binding(get: { sheet == .details ? nil : sheet }, set: { value in
            if value != nil || sheet != .details { sheet = value }
        })
    }

    private var detailInspection: Binding<PlantInspection?> {
        Binding(get: {
            guard sheet == .details, let id = detailCopyID else { return nil }
            return PlantInspection(id: id)
        }, set: { value in
            if value == nil && sheet == .details { sheet = nil }
        })
    }

    private var storageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.showingCached { Label("Saved plants · Connect to refresh", systemImage: "wifi.slash").font(.callout) }
                if let message = store.message { Text(message).font(.callout) }
                if store.inventory.isEmpty { Text("No stored copies in the saved inventory.") }
                JournalGrid {
                    ForEach(store.inventory) { plant in
                        OwnedPlantTile(plant: plant, store: store, catalog: catalog,
                            identifier: "storage.copy." + plant.id.uuidString) {
                            storageInspection = PlantInspection(id: plant.id)
                        }
                    }
                }
                InventoryPagination(store: store)
            }.padding(16)
        }.background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action).navigationTitle("Storage")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            .fullScreenCover(item: $storageInspection, onDismiss: {
                if placedFromStorageInspector {
                    placedFromStorageInspector = false; sheet = nil
                }
            }) { selection in
                OwnedPlantDetailScreen(store: store, copyID: selection.id, catalog: catalog, context: .storagePlacement,
                    placed: { placedFromStorageInspector = true; storageInspection = nil })
                    .journalModalBackground()
            }
    }

}

/// Lives in the reserved editing panel: the scene stays mounted and active.
@MainActor
struct GardenRotationControls: View {
    @ObservedObject var store: GardenEditorStore
    @FocusState private var editingAngle: Bool
    private var angle: Binding<Double> {
        Binding(get: { NSDecimalNumber(decimal: store.candidate?.rotation ?? 0).doubleValue },
                set: { store.updateRotation($0) })
    }
    var body: some View {
        VStack(spacing: 8) {
            Text("Rotate plant").font(.system(.headline, design: .serif))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Slider(value: angle, in: 0...359.99, step: 0.01,
                       onEditingChanged: { if $0 { editingAngle = false } })
                    .frame(minHeight: 44).accessibilityLabel("Rotation in degrees")
                    .accessibilityIdentifier("editor.rotation")
                HStack(spacing: 2) {
                    TextField("Degrees", value: angle, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                        .textFieldStyle(.roundedBorder).focused($editingAngle)
                        .frame(width: 80).frame(minHeight: 44)
                        .accessibilityLabel("Degrees").accessibilityIdentifier("editor.angle")
                    Text("°").accessibilityHidden(true)
                }
            }.disabled(!store.canEdit)
            HStack(spacing: 12) {
                Button("Cancel") { editingAngle = false; store.cancelCandidate() }
                    .frame(minHeight: 44).accessibilityIdentifier("editor.cancel")
                Spacer(minLength: 0)
                Button("Apply") { editingAngle = false; Task { await store.releaseCandidate() } }
                    .frame(minHeight: 44)
                    .disabled(store.candidate?.validity != .valid || !store.canEdit)
                    .accessibilityIdentifier("editor.apply")
            }.buttonStyle(.bordered).controlSize(.regular)
        }.padding(.horizontal, 16).padding(.bottom, 8)
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action).background(JournalTheme.paper)
            .accessibilityIdentifier("editor.rotationPanel")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingAngle = false }
                }
            }
    }
}

@MainActor
private struct CandidateControlsScreen: View {
    @ObservedObject var store: GardenEditorStore
    let close: () -> Void
    @State private var x: Double = 0
    @State private var y: Double = 0
    @State private var angle: Double = 0
    @State private var applying = false
    private enum Field: Hashable { case x, y, angle }
    @FocusState private var focusedField: Field?
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Position plant").font(.system(.headline, design: .serif))
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text("X").font(.caption)
                    TextField("X", value: $x, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad).focused($focusedField, equals: .x).frame(minHeight: 44)
                        .accessibilityLabel("X coordinate").accessibilityIdentifier("editor.x")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Y").font(.caption)
                    TextField("Y", value: $y, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad).focused($focusedField, equals: .y).frame(minHeight: 44)
                        .accessibilityLabel("Y coordinate").accessibilityIdentifier("editor.y")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Degrees").font(.caption)
                    TextField("Degrees", value: $angle, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad).focused($focusedField, equals: .angle).frame(minHeight: 44)
                        .accessibilityLabel("Degrees").accessibilityIdentifier("editor.angle")
                }
            }.textFieldStyle(.roundedBorder)
            Slider(value: $angle, in: 0...359.99, step: 0.01).frame(minHeight: 44).accessibilityLabel("Rotation in degrees")
            HStack {
                Button("Cancel") { focusedField = nil; store.cancelCandidate(); close() }
                    .frame(minHeight: 44).accessibilityIdentifier("editor.cancel")
                Spacer(minLength: 8)
                Button("Apply and save") {
                    focusedField = nil; applying = true
                    Task { await store.releaseCandidate(); close() }
                }.frame(minHeight: 44).disabled(applying || store.candidate?.validity != .valid || !store.canEdit)
                    .accessibilityIdentifier("editor.savePosition")
            }.buttonStyle(.bordered)
        }.padding(12).foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .accessibilityIdentifier("editor.positionPanel")
            .toolbar { ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            } }
            .onAppear {
                if let candidate = store.candidate {
                    x = NSDecimalNumber(decimal: candidate.x).doubleValue
                    y = NSDecimalNumber(decimal: candidate.y).doubleValue
                    angle = NSDecimalNumber(decimal: candidate.rotation).doubleValue
                }
            }
            .onChange(of: x) { store.updatePosition(x: $0, y: y) }
            .onChange(of: y) { store.updatePosition(x: x, y: $0) }
            .onChange(of: angle) { store.updateRotation($0) }
            .onDisappear {
                // Membership preflight may clear the preview while its captured
                // placement is still being submitted. Do not cancel that intent.
                if !applying { store.cancelCandidate() }
            }
    }
}

@MainActor
struct GardenHostScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var sample: GardenStore
    let catalog: any AssetCatalogProviding
    var active: Bool
    var body: some View {
        if let editor = connection.editor {
            ConnectedGardenScreen(store: editor, catalog: catalog, active: active, activitySync: connection.activitySync,
                                  visitors: connection.visitors).id(editor.id)
        } else if connection.connecting {
            ProgressView("Connecting to your garden…")
        } else if !connection.savedURL.isEmpty {
            VStack(spacing: 16) {
                Text("Your garden connection needs attention").font(.title2)
                Text("Sign in again through Settings → Account and sign-in to reconnect. Your saved requests are retained.")
                NavigationLink("Account and sign-in") { AccountScreen(connection: connection, catalog: catalog) }
            }.padding()
        } else {
            GardenScreen(store: sample, catalog: catalog, active: active)
        }
    }
}
