#if DEBUG || INTERNAL_TOOLS
import SwiftUI

struct DeveloperToolsScreen: View {
    let catalog: any AssetCatalogProviding
    @ObservedObject var activity: ActivityStore
    @ObservedObject var connection: GardenConnection
    var body: some View {
        List {
            Section("Current session") {
                NavigationLink("Diagnostics") { DiagnosticsScreen(connection: connection) }
                    .accessibilityIdentifier("developer.diagnostics.link")
                if connection.authentication == nil && connection.configurationIssue == nil {
                    NavigationLink("Garden connection") { GardenConnectionScreen(connection: connection, catalog: catalog) }
                        .accessibilityIdentifier("settings.connection")
                }
            }
            Section("Rendering") {
                NavigationLink("Asset inspector") { AssetInspectorScreen(catalog: catalog) }
                NavigationLink("Garden scenes") { SceneLabScreen(catalog: catalog) }
            }
            Section("Activity") {
                NavigationLink("Health diagnostics") { HealthDiagnosticsScreen(store: activity) }
                NavigationLink("Sample activity") { ActivityFixtureScreen(scenario: .populated) }
                NavigationLink("Empty activity") { ActivityFixtureScreen(scenario: .empty) }
                NavigationLink("Query failures") { ActivityFixtureScreen(scenario: .failure) }
                NavigationLink("Health unavailable") { ActivityFixtureScreen(scenario: .unavailable) }
            }
            Section {
                Text("All scene layouts are development examples. Board dimensions and plant clearance have not been approved. Diagnostics never award growth or tickets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Developer tools")
    }
}

struct ActivityFixtureScreen: View {
    @StateObject private var store: ActivityStore
    init(scenario: FixtureHealthDataProvider.Scenario) {
        _store = StateObject(wrappedValue: ActivityStore(provider: FixtureHealthDataProvider(scenario: scenario)))
    }
    var body: some View { ActivityScreen(store: store) }
}

struct RenderDiagnostics: View {
    @ObservedObject var renderer: RealityGardenRenderer
    var body: some View {
        Section("Renderer") {
            DetailRow(title: "Models loaded", value: "\(renderer.loadedCount)")
            DetailRow(title: "Scene load", value: String(format: "%.2f s", renderer.loadSeconds))
            DetailRow(title: "Mean scene-update interval", value: String(format: "%.1f ms", renderer.sceneUpdateMilliseconds))
            Text("Scene updates are not a GPU frame-time measurement. Use Instruments on the iPhone for rendering and memory profiling.")
                .font(.caption).foregroundStyle(.secondary)
            if let point = renderer.lastGroundPoint {
                DetailRow(title: "Board-local ground point", value: String(format: "x %.3f, y %.3f", point.x, point.y))
            }
            ForEach(Array(renderer.errors.enumerated()), id: \.offset) { _, error in Text(error).foregroundStyle(.red) }
        }
        Section("Imported plants") {
            ForEach(renderer.diagnostics) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label).font(.headline)
                    Text(item.orientation)
                    Text("Playable clips: \(item.animationCount)")
                    Text(String(format: "Bounds X/Y/Z: %.3f / %.3f / %.3f m", item.bounds.x, item.bounds.y, item.bounds.z))
                    Text(String(format: "Lowest point: %.4f m", item.minimumY))
                }.font(.caption).textSelection(.enabled)
            }
        }
    }
}

struct SceneLabScreen: View {
    let catalog: any AssetCatalogProviding
    @StateObject private var renderer = RealityGardenRenderer()
    @State private var preset = DevelopmentScene.mixed
    @State private var wind = true
    @State private var bounds = false
    @State private var ground = false
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            GardenSceneView(renderer: renderer, garden: preset.garden(), catalog: catalog,
                            motionEnabled: wind && !reduceMotion, active: visible && phase == .active,
                            showBounds: bounds, groundPicking: ground).frame(height: 300).accessibilityHidden(true)
            Form {
                Section("Scene") {
                    Picker("Preset", selection: $preset) { ForEach(DevelopmentScene.allCases) { Text($0.title).tag($0) } }
                    Toggle("Wind", isOn: $wind)
                    Toggle("Visual bounds guides", isOn: $bounds)
                    Toggle("Tap ground beneath foliage", isOn: $ground)
                    Button("Reset camera") { renderer.resetCamera() }
                    Button("Reload scene") { renderer.retry(preset.garden(), catalog: catalog) }
                }
                RenderDiagnostics(renderer: renderer)
            }
        }.navigationTitle("Garden scenes").navigationBarTitleDisplayMode(.inline)
            .onAppear { visible = true }
            .onDisappear { visible = false; renderer.stop() }
    }
}

struct AssetInspectorScreen: View {
    let catalog: any AssetCatalogProviding
    @StateObject private var renderer = RealityGardenRenderer()
    @State private var species = "oak"
    @State private var variant = "standard"
    @State private var stage = GrowthStage.adult
    @State private var wind = true
    @State private var bounds = true
    @State private var visible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var variants: [String] { catalog.species.first { $0.speciesId == species }?.variantIds ?? [] }
    private var resolvedVariant: String { variants.contains(variant) ? variant : (variants.first ?? "standard") }
    private var garden: GardenSnapshot {
        var value = DevelopmentScene.single.garden()
        let existing = value.plants[0]
        value.plants[0] = GardenPlant(id: existing.id, speciesId: species, variantId: resolvedVariant,
            assetVersion: "1.0.0", growthStage: stage, x: existing.x, y: existing.y, rotationDegrees: existing.rotationDegrees)
        return value
    }
    var body: some View {
        VStack(spacing: 0) {
            GardenSceneView(renderer: renderer, garden: garden, catalog: catalog,
                            motionEnabled: wind && !reduceMotion, active: visible && phase == .active,
                            showBounds: bounds).frame(height: 300).accessibilityHidden(true)
            Form {
                Section("Asset") {
                    Picker("Species", selection: $species) { ForEach(catalog.species, id: \.speciesId) { Text($0.displayName).tag($0.speciesId) } }
                    Picker("Variant", selection: $variant) { ForEach(variants, id: \.self) { Text($0.capitalized).tag($0) } }
                    Picker("Stage", selection: $stage) { ForEach(GrowthStage.allCases) { Text($0.title).tag($0) } }
                    Toggle("Wind", isOn: $wind)
                    Toggle("Visual bounds guides", isOn: $bounds)
                    Button("Reset camera") { renderer.resetCamera() }
                    Button("Reload asset") { renderer.retry(garden, catalog: catalog) }
                    PlantThumbnail(plant: garden.plants[0], catalog: catalog).frame(height: 100).frame(maxWidth: .infinity)
                    Text("Stage changes preserve the ground anchor and true relative scale. Bounds guides describe foliage, not reserved clearance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                RenderDiagnostics(renderer: renderer)
            }
        }.navigationTitle("Asset inspector").navigationBarTitleDisplayMode(.inline)
            .onChange(of: species) { _ in variant = "standard" }
            .onAppear { visible = true }
            .onDisappear { visible = false; renderer.stop() }
    }
}

struct HealthDiagnosticsScreen: View {
    @ObservedObject var store: ActivityStore
    var body: some View {
        List {
            Section("Read status") {
                DetailRow(title: "Health available", value: store.provider.isAvailable ? "Yes" : "No")
                DetailRow(title: "Request attempted", value: store.hasRequestedAccess ? "Yes — read access remains unknown" : "No")
                DetailRow(title: "Diagnostic timezone", value: store.timeZone.identifier)
                Text("These are observations, not rewarded activity. No baseline, upload or workout reward deduplication runs here.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Request access") { Task { await store.connect() } }.disabled(store.isLoading || !store.provider.isAvailable)
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.isLoading || !store.hasRequestedAccess)
                if store.isLoading { ProgressView("Reading…") }
                if let issue = store.requestIssue { Text(issue) }
            }
            if let report = store.report {
                Section("Step buckets") {
                    if let issue = report.stepsIssue { Text(issue) }
                    ForEach(report.days) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.start.ISO8601Format())
                            Text("Until \(day.end.ISO8601Format())")
                            Text(day.steps.map { "\($0) steps" } ?? "No readable data")
                        }.font(.caption).textSelection(.enabled)
                    }
                }
                Section("Workout observations") {
                    if let issue = report.workoutsIssue { Text(issue) }
                    if report.workouts.isEmpty { Text("No readable workouts.") }
                    ForEach(report.workouts) { workout in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workout.title).font(.headline)
                            Text(workout.id.uuidString)
                            Text("\(workout.start.ISO8601Format()) → \(workout.end.ISO8601Format())")
                            Text("\(Int(workout.durationSeconds)) seconds")
                            Text(workout.distanceMetres.map { String(format: "%.0f metres (workout aggregate)", $0) } ?? "Distance unavailable")
                            Text("Source: \(workout.sourceName) · \(workout.sourceBundleIdentifier)")
                            Text("Manually entered: \(workout.wasUserEntered.map { $0 ? "Yes" : "No" } ?? "Not provided")")
                        }.font(.caption).textSelection(.enabled)
                    }
                }
            }
        }.navigationTitle("Health diagnostics").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
