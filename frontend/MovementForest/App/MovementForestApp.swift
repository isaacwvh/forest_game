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

private enum RootAccountSheet: String, Identifiable {
    case settings, profile, gems
    var id: String { rawValue }
}

@MainActor
struct RootView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject private var connection: GardenConnection
    @Environment(\.scenePhase) private var phase
    @State private var selectedTab = ForestDestination.garden
    @State private var accountSheet: RootAccountSheet?
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
        resume.foreground && accountSheet == nil && !menuPresented && !packOpeningPresented && !childEntryBlocked && !focusedEditing && connection.levelUps?.presented == nil
    }

    private var levelUpAllowed: Bool {
        resume.foreground && accountSheet == nil && !menuPresented && !packOpeningPresented &&
            !childEntryBlocked && !focusedEditing && !entryRecap.showing &&
            (connection.levelUps?.presented != nil ||
                (connection.activitySync?.busy != true && connection.editor?.connectionBusy != true))
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
        if ProcessInfo.processInfo.arguments.contains("--fixture-effects") {
            RewardEffectsFixtureScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--fixture-collection") {
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
                            active: selectedTab == .garden && accountSheet == nil && !menuPresented && collectionDestination == nil && !entryRecap.showing && connection.levelUps?.presented == nil,
                            openProfile: presentProfile)
                            .toolbar(focusedEditing ? .visible : .hidden, for: .navigationBar)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                if !focusedEditing { homeNavigation }
                            }
                            .background(JournalTheme.paper.ignoresSafeArea(edges: .top))
                    }
                    .opacity(selectedTab == .garden ? 1 : 0)
                    .allowsHitTesting(selectedTab == .garden)
                    .accessibilityHidden(selectedTab != .garden)
                    if selectedTab == .myPlants {
                        NavigationStack {
                            MyPlantsHostScreen(connection: connection, catalog: catalog)
                                .toolbar { menuButton; accountButtons }
                        }
                    }
                    if selectedTab == .activity {
                        NavigationStack {
                            ConnectedActivityScreen(connection: connection, store: container.activity, assets: catalog)
                                .toolbar { menuButton; accountButtons }
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
                                accountButtons
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
                                    Text("Your forest").font(.system(.title2, design: .serif).weight(.semibold))
                                    Spacer()
                                    Button { menuPresented = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                        .buttonStyle(.journalIcon)
                                        .accessibilityLabel("Close menu")
                                }.padding()
                                List(CollectionDestination.allCases) { destination in
                                    Button {
                                        collectionDestination = destination; menuPresented = false
                                    } label: {
                                        Label(destination.rawValue, systemImage: destination.symbol)
                                            .font(.system(.headline, design: .serif))
                                            .frame(minHeight: 44).padding(.vertical, 4)
                                    }
                                        .buttonStyle(.journalQuiet)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparatorTint(JournalTheme.vine.opacity(0.35))
                                        .accessibilityIdentifier("menu.\(destination.id)")
                                }.listStyle(.plain).scrollContentBackground(.hidden)
                                Button("Return to Garden") {
                                    collectionDestination = nil; selectedTab = .garden; menuPresented = false
                                }.buttonStyle(.journalSecondary).frame(maxWidth: .infinity, minHeight: 44).padding()
                                    .background(JournalTheme.sage.opacity(0.65))
                            }
                            .frame(width: min(300, geometry.size.width * 0.85))
                            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
                            .background(JournalPageBackground().ignoresSafeArea())
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
                .allowsHitTesting(connection.levelUps?.presented == nil)
                .accessibilityHidden(connection.levelUps?.presented != nil)
                .overlay {
                    if let coordinator = connection.levelUps, let notice = coordinator.presented {
                        LevelUpPopup(notice: notice, dismiss: coordinator.dismiss)
                    }
                }
                .task(id: connection.levelUps?.id) { connection.levelUps?.setEligible(levelUpAllowed) }
                .onChange(of: levelUpAllowed) { connection.levelUps?.setEligible($0) }
                .sheet(item: $accountSheet) { destination in
                    NavigationStack {
                        Group {
                            if destination == .settings {
                                SettingsScreen(catalog: catalog, activity: container.activity, connection: container.connection,
                                               sampleGarden: container.garden.garden)
                            } else {
                                ProfileHostScreen(connection: connection, catalog: catalog,
                                    section: destination == .gems ? .currency : .overview)
                            }
                        }.toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { accountSheet = nil }.buttonStyle(.journalQuiet)
                                .accessibilityIdentifier("accountSheet.done")
                        } }
                    }
                }
                .sheet(isPresented: $entryRecap.showing, onDismiss: {
                    entryRecap.dismissed(allowEffects: entryAllowed && selectedTab == .garden && collectionDestination == nil)
                }) {
                    ActivityRecapScreen(recap: entryRecap, health: container.activity,
                        gameTimezone: container.connection.editor?.profile.gameTimezone ?? TimeZone.current.identifier,
                        catalogue: container.connection.editor?.catalogue, assets: catalog)
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
                    if accountSheet != .settings { accountSheet = nil }
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
                .buttonStyle(.journalNavigation(selectedTab == destination && collectionDestination == nil))
                .foregroundStyle(selectedTab == destination && collectionDestination == nil ? JournalTheme.action : JournalTheme.secondary)
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
            .background(JournalTheme.paper.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { JournalTheme.vine.opacity(0.25).frame(height: 0.5) }
    }

    private var homeNavigation: some View {
        HomeNavigationBar(openMenu: { menuPresented = true }, openProfile: { presentProfile(.overview) },
                          openSettings: { accountSheet = .settings }) {
            if let store = connection.accountSummary {
                HomeLevelProgress(store: store, openProfile: { presentProfile(.overview) })
            } else {
                Text("Your forest").font(.system(.headline, design: .serif))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func presentProfile(_ section: ProfileSection) {
        guard accountSheet == nil, !entryRecap.showing, !packOpeningPresented, !childEntryBlocked, !focusedEditing else { return }
        accountSheet = section == .currency ? .gems : .profile
    }

    private var accountButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { presentProfile(.overview) } label: { Image(systemName: "person.crop.circle").frame(width: 44, height: 44) }
                .buttonStyle(.journalIcon).accessibilityLabel("Profile").accessibilityIdentifier("account.profile")
            Button { accountSheet = .settings } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                .buttonStyle(.journalIcon)
                .accessibilityLabel("Settings")
        }
    }

    private var menuButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { menuPresented = true } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }
                .buttonStyle(.journalIcon)
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
