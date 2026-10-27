import SwiftUI

@main
@MainActor
struct MovementForestApp: App {
    @StateObject private var container = AppContainer()
    var body: some Scene {
        WindowGroup {
            RootView(container: container).tint(.forestTint).preferredColorScheme(.light)
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
        VisitorModelLibrary.shared.preload()
        loadCatalog()
    }

    func loadCatalog() {
        do { catalog = try BundleAssetCatalog(); startupError = nil }
        catch {
            PlayerMessage.recordFailure("Assets", error)
            startupError = "Garden artwork couldn’t load. Try again."
        }
    }
}

enum ForestDestination: String, CaseIterable, Identifiable {
    case myPlants = "My plants", garden = "Garden", edit = "Edit", activity = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .myPlants: return "leaf"
        case .garden: return "tree"
        case .edit: return "pencil"
        case .activity: return "figure.walk"
        }
    }
}

@MainActor
struct RootView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject private var connection: GardenConnection
    @Environment(\.scenePhase) private var phase
    @State private var selectedTab = ForestDestination.garden
    @State private var settingsPresented = false
    @State private var menuPresented = false
    @State private var collectionDestination: CollectionDestination?
    @State private var packOpeningPresented = false
    @State private var childEntryBlocked = false
    @State private var bottomNavigationTop: CGFloat?
    @StateObject private var entryRecap = AppEntryRecapCoordinator()
    @StateObject private var resume = AppResumeCoordinator()

    init(container: AppContainer) {
        self.container = container
        self.connection = container.connection
    }

    private var focusedEditing: Bool { connection.editor?.editing == true }

    private var entryAllowed: Bool {
        resume.foreground && !settingsPresented && !menuPresented && !packOpeningPresented && !childEntryBlocked && !focusedEditing
    }

    private func sceneChanged(to value: ScenePhase) {
        // Use the event value. The callback's captured environment can still
        // describe the preceding scene phase during the transition.
        if resume.sceneChanged(to: value, recap: entryRecap) { presentEntryIfReady() }
    }

    private func presentEntryIfReady() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture-garden") { return }
        #endif
        guard resume.foreground else { return }
        guard let sync = connection.activitySync,
              let editor = connection.editor, sync.isAttached(to: editor) else {
            if !connection.connecting, let catalog = container.catalog {
                resume.connectIfNeeded { await connection.connectManaged(assets: catalog) }
            }
            return
        }
        entryRecap.connectionChanged(to: sync)
        let reconciliation = resume.reconciliation(for: sync)
        guard entryAllowed else { entryRecap.skipEntry(editor: editor); return }
        if entryRecap.begin(sync: sync, editor: editor, reconciliation: reconciliation) {
            selectedTab = .garden
            collectionDestination = nil
        }
    }

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture-collection") {
            CollectionCleanupFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--fixture-pack") {
            PackOpeningFixtureScreen()
        } else { application }
        #else
        application
        #endif
    }

    private var application: some View {
        Group {
            if let catalog = container.catalog {
                // Reserve actual layout space so nested navigation stacks and
                // scrollable pages cannot extend beneath the bottom navigation.
                VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                ZStack {
                    // Always mounted: browsing and Edit use this same renderer/camera.
                    NavigationStack {
                        GardenHostScreen(connection: container.connection, sample: container.garden, catalog: catalog,
                            active: selectedTab == .garden && !settingsPresented && !menuPresented && collectionDestination == nil && !entryRecap.showing)
                            .toolbar { if !focusedEditing { menuButton; settingsButton } }
                    }
                    .opacity(selectedTab == .garden ? 1 : 0)
                    .allowsHitTesting(selectedTab == .garden)
                    .accessibilityHidden(selectedTab != .garden)
                    if selectedTab == .myPlants {
                        NavigationStack {
                            MyPlantsHostScreen(connection: connection, catalog: catalog)
                                .toolbar { menuButton; settingsButton }
                        }
                    }
                    if selectedTab == .activity {
                        NavigationStack {
                            ConnectedActivityScreen(connection: connection, store: container.activity)
                                .toolbar { menuButton; settingsButton }
                        }
                    }
                }
                .opacity(collectionDestination == nil ? 1 : 0)
                .allowsHitTesting(collectionDestination == nil && !menuPresented)
                .accessibilityHidden(collectionDestination != nil || menuPresented)
                if let destination = collectionDestination {
                    NavigationStack {
                        CollectionHostScreen(connection: container.connection, destination: destination, assets: catalog,
                                             navigate: { collectionDestination = $0; if $0 == nil { selectedTab = .garden } },
                                             openingChanged: { packOpeningPresented = $0 })
                            .toolbar {
                                menuButton
                                settingsButton
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
                                    collectionDestination = nil; selectedTab = .garden; menuPresented = false
                                }.padding()
                            }
                            .frame(width: min(300, geometry.size.width * 0.85))
                            .background(Color(uiColor: .systemBackground))
                        }
                    }.accessibilityElement(children: .contain)
                }
                }
                if !focusedEditing {
                    bottomNavigation
                }
                }
                .environment(\.gardenBottomNavigationTop, bottomNavigationTop)
                .onPreferenceChange(GardenBottomNavigationTop.self) { bottomNavigationTop = $0 }
                .sheet(isPresented: $settingsPresented) {
                    NavigationStack {
                        SettingsScreen(catalog: catalog, activity: container.activity, connection: container.connection,
                                       sampleGarden: container.garden.garden)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsPresented = false } } }
                    }
                }
                .sheet(isPresented: $entryRecap.showing, onDismiss: { entryRecap.dismissed() }) {
                    ActivityRecapScreen(recap: entryRecap, catalogue: container.connection.editor?.catalogue, assets: catalog)
                }
                .onChange(of: connection.activitySync?.id) { id in
                    if id == nil { resume.resetConnection(); entryRecap.signOut() }
                    else { presentEntryIfReady() }
                }
                .onChange(of: connection.connecting) { busy in if !busy { presentEntryIfReady() } }
                .onChange(of: connection.editor?.profile.userId) { user in
                    if user == nil { entryRecap.signOut() }
                    DiagnosticHistory.shared.setScope(connection.editor?.diagnosticScope)
                    selectedTab = .garden; menuPresented = false; collectionDestination = nil
                }
                .onChange(of: entryAllowed) { _ in presentEntryIfReady() }
                .onPreferenceChange(EntryPresentationBlocker.self) { childEntryBlocked = $0 }
                .onChange(of: selectedTab) { _ in
                    if !entryRecap.showing, let editor = connection.editor { entryRecap.skipEntry(editor: editor) }
                }
                .task {
                    // Initialize once, before suspension. Never replay an old
                    // environment snapshot after authentication finishes.
                    if resume.initializeSceneIfNeeded(to: phase, recap: entryRecap) { presentEntryIfReady() }
                    if container.garden.garden == nil { await container.garden.load() }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--fixture-garden") {
                        await connection.installPresentationFixture(assets: catalog)
                        return
                    }
                    #endif
                    if !ProcessInfo.processInfo.arguments.contains("--fixture-health") {
                        await container.connection.restore(assets: catalog)
                    }
                    presentEntryIfReady()
                }
                .onChange(of: phase) { value in
                    sceneChanged(to: value)
                }
            } else {
                RecoveryView(title: "Your forest couldn’t load", message: container.startupError ?? "Resources are unavailable.",
                             actionTitle: "Try again", action: container.loadCatalog)
            }
        }
    }

    private func navigate(to destination: ForestDestination) {
        if destination == .edit {
            guard let editor = connection.editor, editor.canEdit else { return }
            collectionDestination = nil; selectedTab = .garden; menuPresented = false
            editor.editing = true
        } else {
            collectionDestination = nil; selectedTab = destination
        }
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            ForEach(ForestDestination.allCases) { destination in
                Button { navigate(to: destination) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: destination.symbol).font(.body)
                        Text(destination.rawValue).font(.caption).lineLimit(2).minimumScaleFactor(0.8)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, minHeight: 50)
                }
                .foregroundStyle(selectedTab == destination && collectionDestination == nil ? Color.forestTint : Color.secondary)
                .disabled(destination == .edit && connection.editor?.canEdit != true)
                .accessibilityIdentifier("navigation." + destination.id)
                .accessibilityLabel(destination.rawValue)
                .accessibilityAddTraits(selectedTab == destination && collectionDestination == nil ? .isSelected : [])
            }
        }.padding(.horizontal, 8).padding(.top, 4)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: GardenBottomNavigationTop.self, value: geometry.frame(in: .global).minY)
            })
            .allowsHitTesting(!menuPresented).accessibilityHidden(menuPresented)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) { Divider() }
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
