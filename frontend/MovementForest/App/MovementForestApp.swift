import SwiftUI

@main
@MainActor
struct MovementForestApp: App {
    @StateObject private var container = AppContainer()
    var body: some Scene {
        WindowGroup { RootView(container: container).tint(.forestTint) }
    }
}

@MainActor
final class AppContainer: ObservableObject {
    @Published private(set) var catalog: BundleAssetCatalog?
    @Published private(set) var startupError: String?
    let garden = GardenStore(repository: SampleGardenRepository())
    let activity: ActivityStore

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--fixture-health") {
            let scenario: FixtureHealthDataProvider.Scenario = arguments.contains("--empty-health") ? .empty :
                (arguments.contains("--failed-health") ? .failure : .populated)
            activity = ActivityStore(provider: FixtureHealthDataProvider(scenario: scenario))
        } else {
            activity = ActivityStore(provider: HealthKitService())
        }
        #else
        activity = ActivityStore(provider: HealthKitService())
        #endif
        loadCatalog()
    }

    func loadCatalog() {
        do { catalog = try BundleAssetCatalog(); startupError = nil }
        catch { startupError = error.localizedDescription }
    }
}

struct RootView: View {
    @ObservedObject var container: AppContainer
    @Environment(\.scenePhase) private var phase
    @State private var selectedTab = 0
    @State private var settingsPresented = false

    var body: some View {
        Group {
            if let catalog = container.catalog {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        GardenScreen(store: container.garden, catalog: catalog, active: selectedTab == 0 && !settingsPresented)
                            .toolbar { settingsButton }
                    }
                    .tabItem { Label("Garden", systemImage: "leaf") }.tag(0)
                    NavigationStack {
                        ActivityScreen(store: container.activity)
                            .toolbar { settingsButton }
                    }
                    .tabItem { Label("Activity", systemImage: "figure.walk") }.tag(1)
                }
                .sheet(isPresented: $settingsPresented) {
                    NavigationStack {
                        SettingsScreen(catalog: catalog, activity: container.activity)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsPresented = false } } }
                    }
                }
                .task {
                    if container.garden.garden == nil { await container.garden.load() }
                    await container.activity.refresh()
                }
                .onChange(of: phase) { value in
                    if value == .active { Task { await container.activity.refresh() } }
                }
            } else {
                RecoveryView(title: "Your forest couldn’t load", message: container.startupError ?? "Resources are unavailable.",
                             actionTitle: "Try again", action: container.loadCatalog)
            }
        }
    }

    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { settingsPresented = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                .accessibilityLabel("Settings")
        }
    }
}

extension Color {
    static let forestTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.56, green: 0.80, blue: 0.59, alpha: 1) :
            UIColor(red: 0.20, green: 0.39, blue: 0.25, alpha: 1)
    })
}
