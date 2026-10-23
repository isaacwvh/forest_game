import SwiftUI

@main
@MainActor
struct MovementForestApp: App {
    @StateObject private var container = AppContainer()
    var body: some Scene {
        WindowGroup {
            RootView(container: container).tint(.forestTint)
                .onOpenURL { url in Task { await container.connection.authentication?.handleCallback(url) } }
        }
    }
}

@MainActor
final class AppContainer: ObservableObject {
    @Published private(set) var catalog: BundleAssetCatalog?
    @Published private(set) var startupError: String?
    let garden = GardenStore(repository: SampleGardenRepository())
    let connection = GardenConnection()
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
        connection.configureHealth(activity)
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
    @State private var menuPresented = false
    @State private var collectionDestination: CollectionDestination?

    var body: some View {
        Group {
            if let catalog = container.catalog {
                ZStack(alignment: .leading) {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        GardenHostScreen(connection: container.connection, sample: container.garden, catalog: catalog,
                                         active: selectedTab == 0 && !settingsPresented && !menuPresented && collectionDestination == nil)
                            .toolbar { menuButton; settingsButton }
                    }
                    .tabItem { Label("Garden", systemImage: "leaf") }.tag(0)
                    NavigationStack {
                        ConnectedActivityScreen(connection: container.connection, store: container.activity)
                            .toolbar { menuButton; settingsButton }
                    }
                    .tabItem { Label("Activity", systemImage: "figure.walk") }.tag(1)
                }
                .opacity(collectionDestination == nil ? 1 : 0)
                .allowsHitTesting(collectionDestination == nil && !menuPresented)
                .accessibilityHidden(collectionDestination != nil || menuPresented)
                if let destination = collectionDestination {
                    NavigationStack {
                        CollectionHostScreen(connection: container.connection, destination: destination, assets: catalog)
                            .toolbar {
                                menuButton
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("Garden") { collectionDestination = nil; selectedTab = 0 }
                                }
                            }
                    }.id(destination)
                        .allowsHitTesting(!menuPresented).accessibilityHidden(menuPresented)
                }
                if menuPresented {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Button { menuPresented = false } label: { Color.black.opacity(0.3).ignoresSafeArea() }
                                .accessibilityLabel("Close collection menu")
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("Your forest").font(.title2.bold())
                                    Spacer()
                                    Button { menuPresented = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                        .accessibilityLabel("Close menu")
                                }.padding()
                                List(CollectionDestination.allCases) { destination in
                                    Button {
                                        collectionDestination = destination; menuPresented = false
                                    } label: { Label(destination.rawValue, systemImage: destination.symbol).padding(.vertical, 8) }
                                        .accessibilityIdentifier("menu.\(destination.id)")
                                }.listStyle(.plain)
                                Button("Return to Garden") {
                                    collectionDestination = nil; selectedTab = 0; menuPresented = false
                                }.padding()
                            }
                            .frame(width: min(300, geometry.size.width * 0.85))
                            .background(Color(uiColor: .systemBackground))
                        }
                    }.accessibilityElement(children: .contain)
                }
                }
                .sheet(isPresented: $settingsPresented) {
                    NavigationStack {
                        SettingsScreen(catalog: catalog, activity: container.activity, connection: container.connection)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsPresented = false } } }
                    }
                }
                .task {
                    if container.garden.garden == nil { await container.garden.load() }
                    if !ProcessInfo.processInfo.arguments.contains("--fixture-health") {
                        await container.connection.restore(assets: catalog)
                    }
                    await container.activity.refresh()
                }
                .onChange(of: phase) { value in
                    if value == .active { Task {
                        await container.connection.connectManaged(assets: catalog)
                        if let sync = container.connection.activitySync { _ = await sync.synchronize() }
                        await container.activity.refresh()
                    } }
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

    private var menuButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { menuPresented = true } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }
                .accessibilityLabel("Open collection menu").accessibilityIdentifier("collection.menu")
        }
    }
}

extension Color {
    static let forestTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.56, green: 0.80, blue: 0.59, alpha: 1) :
            UIColor(red: 0.20, green: 0.39, blue: 0.25, alpha: 1)
    })
}
