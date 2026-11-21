import Foundation
import Combine
import Security
import CryptoKit

private enum DevelopmentCredential {
    static let service = "MovementForest.DevelopmentAPI"
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "token",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ForestError.invalidData("The saved development credential could not be read. Re-enter your token.")
        }
        return token
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ForestError.invalidData("Your token could not be saved in Keychain.") }
    }
    static func remove() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "token"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ForestError.invalidData("The development token could not be removed from Keychain.")
        }
    }
}

@MainActor
final class GardenConnection: ObservableObject {
    @Published private(set) var expeditions: ExpeditionCoordinator?
    private var expeditionUpdates: AnyCancellable?
    #if DEBUG
    func installPresentationFixture(assets: any AssetCatalogProviding) async {
        do {
            let service = try PresentationGardenService()
            let profile = try await service.profile()
            let store = GardenEditorStore(profile: profile, service: service, assets: assets, journal: PresentationEditJournal())
            editor = store
            editorUpdates = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            if ProcessInfo.processInfo.arguments.contains("--fixture-progression") || ProcessInfo.processInfo.arguments.contains("--fixture-level-up") {
                let summary = try PresentationAccountFixture.store(profile: profile)
                accountSummary = summary
                accountSummaryUpdates = summary.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                await summary.refresh()
                if ProcessInfo.processInfo.arguments.contains("--fixture-level-up"), let snapshot = summary.snapshot {
                    let coordinator = try PresentationLevelFixture.coordinator(summary: snapshot)
                    levelUps = coordinator
                    levelUpUpdates = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                    coordinator.onConsumed = { [weak summary] in summary?.invalidate() }
                    summary.onSummary = { [weak coordinator, weak store] value in
                        coordinator?.receive(value.levelUpNotice)
                        if let benefits = value.benefits { store?.applyLevelPlantLimit(benefits.plantLimit) }
                    }
                    summary.onSummary?(snapshot)
                }
            }
            await store.start()
        } catch { status = "Presentation fixture couldn’t load." }
    }
    #endif
    let authentication: AuthenticationStore?
    let configurationIssue: String?
    @Published private(set) var editor: GardenEditorStore?
    @Published private(set) var activitySync: ActivitySyncCoordinator?
    @Published private(set) var visitors: VisitorCoordinator?
    @Published private(set) var collection: CollectionCoordinator?
    @Published private(set) var accountSummary: AccountSummaryStore?
    @Published private(set) var levelUps: LevelUpCoordinator?
    @Published private(set) var accountRequired = false
    @Published private(set) var connecting = false
    @Published private(set) var status: String?
    @Published private(set) var savedURL: String
    @Published private(set) var titleVisible = true
    @Published private(set) var stagedProfile: APIProfile?
    @Published private(set) var stagedMissingGarden = false
    @Published private(set) var switching = false
    @Published private(set) var updatingProfile = false
    private let defaults: UserDefaults
    private var restored = false
    private var health: ActivityStore?
    private var pendingClient: APIClient?
    private var pendingCredential: String?
    private let disk = AccountDiskStore()
    private var editorUpdates: AnyCancellable?
    private var syncUpdates: AnyCancellable?
    private var visitorUpdates: AnyCancellable?
    private var collectionUpdates: AnyCancellable?
    private var accountSummaryUpdates: AnyCancellable?
    private var levelUpUpdates: AnyCancellable?

    private func clearLevelUps() {
        levelUps?.deactivate(); levelUps = nil; levelUpUpdates = nil
    }
    private var authUpdates: AnyCancellable?
    private var managedTokens: ScopedAuthTokenProvider?
    private var managedProfileVerified = false
    private var managedGeneration = UUID()
    private var pendingIdentity: AuthIdentity?
    private var openAfterConnection = false
    private var committingAccount = false
    private static let urlKey = "development.gardenAPI.url.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuredAuth: AuthenticationStore?
        let issue: String?
        let initialURL: String
        do {
            #if DEBUG
            let fixture = AuthEntryFixture.authentication()
            #else
            let fixture: AuthenticationStore? = nil
            #endif
            if let fixture = fixture {
                configuredAuth = fixture; initialURL = fixture.configuration.apiURL.absoluteString
            } else if let configuration = try AuthConfiguration.load() {
                configuredAuth = AuthenticationStore(configuration: configuration, service: SupabaseAuthService(configuration: configuration))
                initialURL = configuration.apiURL.absoluteString
            } else { configuredAuth = nil; initialURL = "" }
            issue = nil
        } catch { configuredAuth = nil; issue = error.localizedDescription; initialURL = "" }
        authentication = configuredAuth; configurationIssue = issue; savedURL = initialURL
        #if DEBUG || INTERNAL_TOOLS
        if authentication == nil && configurationIssue == nil { savedURL = defaults.string(forKey: Self.urlKey) ?? "" }
        #endif
    }

    func configureHealth(_ health: ActivityStore) { self.health = health }
    var busy: Bool { connecting || switching || updatingProfile || editor?.connectionBusy == true || activitySync?.busy == true }

    func restore(assets: any AssetCatalogProviding) async {
        if let authentication = authentication {
            guard !restored else { return }; restored = true
            authUpdates = authentication.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            authentication.onSessionChange = { [weak self, weak authentication] in
                guard let self = self, let authentication = authentication else { return }
                if authentication.user == nil || authentication.recoveringPassword ||
                    self.managedTokens?.identity != authentication.user?.identity {
                    self.detachManaged()
                }
                if authentication.user == nil || authentication.recoveringPassword { self.titleVisible = true }
                guard authentication.user != nil, !authentication.recoveringPassword else { return }
                Task { await self.connectManaged(assets: assets) }
            }
            authentication.start()
            await connectManaged(assets: assets, restoreCache: true)
            return
        }
        guard configurationIssue == nil else { status = configurationIssue; return }
        #if DEBUG || INTERNAL_TOOLS
        guard !restored else { return }
        restored = true
        do {
            if !savedURL.isEmpty, let token = try DevelopmentCredential.read() {
                if let data = defaults.data(forKey: "development.gardenAPI.profile.v1"),
                   let profile = try? JSONDecoder().decode(APIProfile.self, from: data),
                   let baseURL = try? APIClient.validatedURL(savedURL) {
                    let client = APIClient(baseURL: baseURL, tokens: FixedTokenProvider(value: token))
                    let store = GardenEditorStore(profile: profile, service: APIGardenRepository(client: client), assets: assets, cache: disk)
                    store.restoreCached()
                    editor = store
                    await store.start(refreshRemote: false)
                    installActivity(client: client, store: store, visitorsEnabled: false)
                }
                await connect(url: savedURL, token: token, assets: assets)
            }
        } catch { status = error.localizedDescription }
        #endif
    }

    func connect(url: String, token: String, assets: any AssetCatalogProviding) async {
        #if DEBUG || INTERNAL_TOOLS
        guard authentication == nil, configurationIssue == nil else { return }
        guard !busy else { return }
        connecting = true; status = "Checking connection…"
        defer { connecting = false }
        do {
            let baseURL = try APIClient.validatedURL(url)
            let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !credential.isEmpty, credential.count <= 16_384,
                  !credential.contains("\n"), !credential.contains("\r") else {
                throw ForestError.invalidData("Enter a development bearer token generated by your backend.")
            }
            let client = APIClient(baseURL: baseURL, tokens: FixedTokenProvider(value: credential))
            let repository = APIGardenRepository(client: client)
            let profile: APIProfile
            do { profile = try await repository.profile() }
            catch let error as APIError where error.code == "account_required" {
                pendingClient = client; pendingCredential = credential; accountRequired = true
                status = "Choose a username and display name to create your account and starter."
                return
            }
            guard editor?.state.busy != true else {
                throw ForestError.invalidData("Wait for the current garden request to finish, then reconnect.")
            }
            try DevelopmentCredential.save(credential)
            savedURL = baseURL.absoluteString
            defaults.set(savedURL, forKey: Self.urlKey)
            defaults.set(try JSONEncoder().encode(profile), forKey: "development.gardenAPI.profile.v1")
            accountRequired = false; pendingClient = nil; pendingCredential = nil
            activitySync?.deactivate(); activitySync = nil
            expeditions?.deactivate(); expeditions = nil; expeditionUpdates = nil
            if let current = editor, !current.recoveryLocked, current.profile.userId == profile.userId,
               current.service.serverID == repository.serverID {
                await current.replaceService(repository)
                installActivity(client: client, store: current)
            } else {
                let store = GardenEditorStore(profile: profile, service: repository, assets: assets, cache: disk)
                editor = store
                await store.start()
                installActivity(client: client, store: store)
            }
            status = "Authenticated as \(profile.displayName)."
        } catch let error as APIError where error.status == 401 {
            status = "The token is invalid or expired. Generate a new development token."
        } catch { status = "Connection failed. \(error.localizedDescription)" }
        #endif
    }

    private struct ManagedProfile: Codable {
        let identity: AuthIdentity
        let server: String
        let profile: APIProfile
    }

    private func detachManaged() {
        accountSummary?.deactivate(); accountSummary = nil; accountSummaryUpdates = nil; clearLevelUps()
        collection?.deactivate(); collection = nil; collectionUpdates = nil
        visitors?.deactivate(); visitors = nil; visitorUpdates = nil
        managedGeneration = UUID(); managedTokens?.invalidate(); managedTokens = nil
        managedProfileVerified = false
        activitySync?.deactivate(); activitySync = nil
            expeditions?.deactivate(); expeditions = nil; expeditionUpdates = nil
        editor?.deactivate(); editor = nil
        editorUpdates = nil; syncUpdates = nil
        pendingIdentity = nil; pendingClient = nil; pendingCredential = nil
        accountRequired = false; connecting = false
    }

    func showTitle() { titleVisible = true }

    func updateProfile(username: String, displayName: String) async {
        guard !busy, let auth = authentication, !auth.busy, let editor = editor,
              managedProfileVerified else { return }
        updatingProfile = true
        let generation = managedGeneration
        defer { updatingProfile = false }
        do {
            let tokens = try auth.scopedTokens()
            let client = APIClient(baseURL: auth.configuration.apiURL, tokens: tokens)
            let server = client.baseURL.absoluteString
            let saved: Data
            if let pending = try disk.load(Data.self, kind: "profile-update", server: server, user: editor.profile.userId) {
                _ = try ActivityWire.decoder().decode(UpdateAccountProfileRequest.self, from: pending)
                saved = pending
            } else {
                saved = try ActivityWire.encoder().encode(UpdateAccountProfileRequest(requestId: UUID(),
                    username: username, displayName: displayName))
                try disk.save(saved, kind: "profile-update", server: server, user: editor.profile.userId)
            }
            let result: APIProfile = try await client.request("v1/me", method: "PATCH", body: saved)
            try tokens.validate()
            guard managedGeneration == generation, result.userId == editor.profile.userId else { return }
            try disk.remove(kind: "profile-update", server: server, user: result.userId)
            editor.applyProfile(result)
            defaults.set(try JSONEncoder().encode(ManagedProfile(identity: tokens.identity, server: server, profile: result)),
                         forKey: "supabase.gameProfile.v1")
            accountSummary?.invalidate()
            status = "Profile saved."
        } catch {
            guard managedGeneration == generation else { return }
            if let error = error as? APIError, (400..<500).contains(error.status),
               ![401, 408, 426, 429].contains(error.status), error.code != "idempotency_conflict" {
                try? disk.remove(kind: "profile-update", server: auth.configuration.apiURL.absoluteString,
                                 user: editor.profile.userId)
            }
            status = PlayerMessage.failure(error, fallback: "Profile save paused. Try again.")
        }
    }

    func enterGarden(assets: any AssetCatalogProviding) async {
        guard authentication?.restoring == false, authentication?.user != nil,
              authentication?.recoveringPassword == false else { return }
        await connectManaged(assets: assets, restoreCache: editor == nil)
        if editor != nil { titleVisible = false }
    }

    private func candidateClient() throws -> (AuthenticationStore, APIClient) {
        guard let target = authentication?.candidate else { throw AuthenticationStore.signInRequired }
        return (target, APIClient(baseURL: target.configuration.apiURL, tokens: try target.scopedTokens()))
    }

    /// Start intent is explicit. Failed creation never removes the current account.
    func startGuest(assets: any AssetCatalogProviding) async {
        guard !switching, !connecting, let auth = authentication,
              auth.configuration.guestEnabled, !auth.busy, !auth.restoring, !auth.restoreUnavailable else { return }
        switching = true; status = "Preparing your garden…"
        defer { switching = false }
        guard await auth.createGuest() else { status = auth.message; return }
        do {
            let (target, client) = try candidateClient()
            guard let identity = target.user?.identity else { throw AuthenticationStore.signInRequired }
            let journal = AccountBootstrapJournal(disk: disk)
            let profile: APIProfile
            do { profile = try await APIGardenRepository(client: client).profile() }
            catch let error as APIError where error.code == "account_required" {
                let saved = try journal.pending(server: client.baseURL.absoluteString, identity: identity,
                                                timezone: TimeZone.current.identifier)
                let result: APIAccount = try await client.request("v1/accounts/bootstrap", method: "POST", body: saved.body)
                profile = result.profile
            }
            try await verifyDestination(profile: profile, client: client)
            try journal.clear(server: client.baseURL.absoluteString, identity: identity)
            stagedProfile = profile
            openAfterConnection = true
            await commitStagedAccount(assets: assets)
        } catch {
            PlayerMessage.recordFailure("Guest setup", error)
            status = PlayerMessage.failure(error, fallback: "Garden setup paused. Try again.")
        }
    }

    func stageGoogle() async {
        guard !switching, !connecting, authentication?.busy == false else { return }
        switching = true; defer { switching = false }
        do {
            let target = try authentication!.prepareCandidate()
            authentication?.markStagedCallback(true)
            defer { authentication?.markStagedCallback(false) }
            let confirmed = await target.google(link: false)
            guard confirmed else { status = target.message; return }
            try await resolveStagedAccount()
        } catch { status = PlayerMessage.failure(error, fallback: "Sign-in paused. Try again.") }
    }

    func stageEmail(email: String, password: String) async {
        guard !switching, !connecting, authentication?.busy == false else { return }
        switching = true; defer { switching = false }
        do {
            let target = try authentication!.prepareCandidate()
            let confirmed = await target.signIn(email: email, password: password)
            guard confirmed, target.user != nil else { status = target.message; return }
            try await resolveStagedAccount()
        } catch { status = PlayerMessage.failure(error, fallback: "Sign-in paused. Try again.") }
    }

    private func verifyDestination(profile: APIProfile, client: APIClient) async throws {
        let garden: APIGarden = try await client.request("v1/me/garden")
        let verified = try await APIGardenRepository(client: client).profile()
        guard garden.gardenId != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              verified.userId == profile.userId else {
            throw AuthenticationStore.signInRequired
        }
    }

    private func resolveStagedAccount() async throws {
        stagedProfile = nil; stagedMissingGarden = false
        let (_, client) = try candidateClient()
        do {
            let profile = try await APIGardenRepository(client: client).profile()
            try await verifyDestination(profile: profile, client: client)
            stagedProfile = profile; status = nil
        } catch let error as APIError where error.code == "account_required" {
            stagedMissingGarden = true; status = "No garden on this account."
        }
    }

    func createStagedGarden(assets: any AssetCatalogProviding) async {
        guard stagedMissingGarden, !switching else { return }
        switching = true; defer { switching = false }
        do {
            let (target, client) = try candidateClient()
            guard let identity = target.user?.identity else { throw AuthenticationStore.signInRequired }
            let journal = AccountBootstrapJournal(disk: disk)
            let saved = try journal.pending(server: client.baseURL.absoluteString, identity: identity,
                                            timezone: TimeZone.current.identifier)
            let result: APIAccount = try await client.request("v1/accounts/bootstrap", method: "POST", body: saved.body)
            try await verifyDestination(profile: result.profile, client: client)
            try journal.clear(server: client.baseURL.absoluteString, identity: identity)
            stagedProfile = result.profile; stagedMissingGarden = false
            await commitStagedAccount(assets: assets)
        } catch { status = PlayerMessage.failure(error, fallback: "Garden setup paused. Try again.") }
    }

    func commitStagedAccount(assets: any AssetCatalogProviding) async {
        guard !committingAccount, let auth = authentication, stagedProfile != nil, !auth.busy else { return }
        committingAccount = true
        let wasSwitching = switching
        switching = true
        defer { committingAccount = false; switching = wasSwitching }
        openAfterConnection = true
        // Pause transmission during the short, local credential handoff. Journals stay intact.
        await visitors?.pause()
        do {
            try await auth.commitCandidate()
            stagedProfile = nil; stagedMissingGarden = false
            await connectManaged(assets: assets)
            if editor != nil { titleVisible = false }
        } catch { openAfterConnection = false; status = "Switch couldn’t finish. Try again." }
    }

    func cancelStagedAccount() async {
        guard !switching else { return }
        await authentication?.cancelCandidate()
        stagedProfile = nil; stagedMissingGarden = false; status = nil
        authentication?.markStagedCallback(false)
    }

    func handleAuthCallback(_ url: URL, assets: any AssetCatalogProviding) async {
        guard let auth = authentication, auth.configuration.accepts(url), !AuthCallbackReceipts.contains(url) else { return }
        if auth.stagedCallbackPending, url.path == auth.configuration.callbackURL.path {
            // ASWebAuthenticationSession owns a live browser return. On a cold
            // callback, reopen the same isolated Keychain/PKCE context instead.
            guard !switching, auth.candidate?.busy != true else { return }
            do {
                let target = try auth.prepareCandidate()
                let confirmed = await target.handleCallback(url)
                guard confirmed, target.user != nil else { status = target.message; return }
                try await resolveStagedAccount()
                titleVisible = true
                auth.markStagedCallback(false)
            } catch { status = "Sign-in link expired. Try again." }
        } else { await auth.handleCallback(url) }
    }

    func connectManaged(assets: any AssetCatalogProviding, restoreCache: Bool = false) async {
        guard let auth = authentication, auth.user != nil, !auth.recoveringPassword, !connecting else { return }
        if let tokens = managedTokens, (try? tokens.validate()) != nil,
           tokens.identity == auth.user?.identity, editor?.isActive == true,
           managedProfileVerified, !restoreCache { return }
        let operation = UUID(); managedGeneration = operation
        LifecycleDiagnostics.event("connection started id=\(operation)")
        connecting = true; status = "Loading your account…"
        defer {
            if managedGeneration == operation { connecting = false }
            LifecycleDiagnostics.event("connection ended id=\(operation)")
        }
        do {
            let tokens = try auth.scopedTokens()
            managedTokens?.invalidate(); managedTokens = tokens
            managedProfileVerified = false
            let client = APIClient(baseURL: auth.configuration.apiURL, tokens: tokens)
            let repository = APIGardenRepository(client: client)
            if restoreCache, let data = defaults.data(forKey: "supabase.gameProfile.v1"),
               let saved = try? JSONDecoder().decode(ManagedProfile.self, from: data),
               saved.identity == tokens.identity, saved.server == repository.serverID {
                let cached = GardenEditorStore(profile: saved.profile, service: repository, assets: assets, cache: disk)
                editor = cached
                await cached.start(refreshRemote: false)
                guard managedGeneration == operation else { cached.deactivate(); return }
                _ = installAccountSummary(client: client, store: cached, remoteEnabled: false)
                // No queued mutations are sent until /me confirms the game identity.
            }
            let profile: APIProfile
            LifecycleDiagnostics.event("account verification started id=\(operation)")
            do { profile = try await repository.profile() }
            catch let error as APIError where error.code == "account_required" {
                guard managedGeneration == operation else { return }
                editor?.deactivate(); editor = nil
                accountSummary?.deactivate(); accountSummary = nil; accountSummaryUpdates = nil; clearLevelUps()
                defaults.removeObject(forKey: "supabase.gameProfile.v1")
                pendingIdentity = tokens.identity; pendingClient = client; accountRequired = true
                status = "Choose your game username and display name."
                return
            }
            try tokens.validate()
            guard managedGeneration == operation else { return }
            LifecycleDiagnostics.event("account verified id=\(operation)")
            defaults.set(try JSONEncoder().encode(ManagedProfile(identity: tokens.identity, server: repository.serverID, profile: profile)),
                         forKey: "supabase.gameProfile.v1")
            accountRequired = false; pendingIdentity = nil; pendingClient = nil
            managedProfileVerified = true
            activitySync?.deactivate(); editor?.deactivate()
            let store = GardenEditorStore(profile: profile, service: repository, assets: assets, cache: disk)
            editor = store
            LifecycleDiagnostics.event("garden bootstrap started id=\(operation)")
            await store.start()
            LifecycleDiagnostics.event("garden bootstrap ended id=\(operation)")
            guard managedGeneration == operation else { store.deactivate(); return }
            installActivity(client: client, store: store)
            guard managedGeneration == operation else { return }
            status = "Signed in as \(profile.displayName)."
            if openAfterConnection { titleVisible = false; openAfterConnection = false }
        } catch {
            guard managedGeneration == operation else { return }
            PlayerMessage.recordFailure("Connection", error)
            status = PlayerMessage.failure(error, fallback: "Account connection paused. Try connecting again. Saved requests are retained.")
        }
    }

    func signOut() async {
        if authentication == nil { disconnect(); return }
        guard !switching, authentication?.busy != true else { return }
        switching = true
        defer { switching = false }
        await visitors?.pause()
        if let authentication = authentication {
            guard !authentication.busy else { return }
            detachManaged()
            defaults.removeObject(forKey: "supabase.gameProfile.v1")
            await authentication.signOut()
            titleVisible = true
        } else { disconnect() }
    }

    private func installAccountSummary(client: APIClient, store: GardenEditorStore,
                                       remoteEnabled: Bool) -> AccountSummaryStore {
        accountSummary?.deactivate()
        clearLevelUps()
        let service: any AccountSummaryServing = remoteEnabled ? APIAccountSummaryRepository(client: client) :
            UnavailableAccountSummaryRepository(serverID: client.baseURL.absoluteString)
        let summary = AccountSummaryStore(userID: store.profile.userId,
            service: service, cache: AccountSummaryDiskStore(disk: disk))
        accountSummary = summary
        if remoteEnabled, let installation = try? InstallationIdentity.load(disk: disk) {
            let coordinator = LevelUpCoordinator(user: store.profile.userId, server: client.baseURL.absoluteString,
                installation: installation, service: APILevelUpRepository(client: client), persistence: LevelUpDiskStore(disk: disk))
            coordinator.onConsumed = { [weak summary] in summary?.invalidate() }
            levelUps = coordinator
            levelUpUpdates = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        accountSummaryUpdates = summary.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if remoteEnabled { Task { [weak summary] in await summary?.refresh() } }
        return summary
    }

    private func installActivity(client: APIClient, store: GardenEditorStore, visitorsEnabled: Bool = true) {
        var client = client
        client.diagnosticScope = store.diagnosticScope
        DiagnosticHistory.shared.setScope(store.diagnosticScope)
        let summary = installAccountSummary(client: client, store: store, remoteEnabled: visitorsEnabled)
        collection?.deactivate(); collection = nil; collectionUpdates = nil
        if visitorsEnabled {
            let discovery = CatalogDiscoveryStore(userID: store.profile.userId,
                service: APICatalogDiscoveryRepository(client: client), cache: CatalogDiscoveryDiskStore(disk: disk))
            let collection = CollectionCoordinator(userID: store.profile.userId,
                service: APICollectionRepository(client: client), discovery: discovery, initialCatalogue: store.catalogue)
            self.collection = collection
            collectionUpdates = collection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            collection.onPlantAwarded = { [weak store] in await store?.refresh() }
            collection.onWallet = { [weak summary] _, version in summary?.economyChanged(version) }
        }
        editorUpdates = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        visitors?.deactivate(); visitors = nil; visitorUpdates = nil
        if visitorsEnabled {
            do {
                let visitor = VisitorCoordinator(userID: store.profile.userId,
                    installationID: try InstallationIdentity.load(disk: disk), service: APIVisitorRepository(client: client))
                visitors = visitor
                visitor.onWallet = { [weak collection = self.collection, weak summary] balance, version in
                    collection?.applyWallet(balance, version: version)
                    summary?.economyChanged(version)
                }
                collection?.onWallet = { [weak visitor, weak summary] balance, version in
                    visitor?.applyWallet(balance, version: version)
                    summary?.economyChanged(version)
                }
                visitorUpdates = visitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                visitor.start()
            } catch {
                PlayerMessage.recordFailure("Visitors", error, scope: store.diagnosticScope)
                status = "Visitors couldn’t start on this iPhone. Reconnect to try again."
            }
        }
        summary.onWallet = { [weak collection = self.collection, weak visitor = self.visitors] balance, version in
            collection?.applyWallet(balance, version: version)
            visitor?.applyWallet(balance, version: version)
        }
        var previousCapacity: Int?
        summary.onSummary = { [weak store, weak collection = self.collection, weak visitor = self.visitors,
                               weak levels = self.levelUps] value in
            levels?.receive(value.levelUpNotice)
            collection?.applyWallet(value.wallet.tokenBalance, version: value.wallet.economyVersion, gems: value.wallet.gemBalance)
            if let benefits = value.benefits {
                store?.applyLevelPlantLimit(benefits.plantLimit)
                collection?.applyLevelPlantLimit(benefits.plantLimit)
                if previousCapacity != benefits.effectiveOfflineCapacity {
                    previousCapacity = benefits.effectiveOfflineCapacity
                    Task { await visitor?.tick(force: true) }
                }
            }
        }
        if let cached = summary.snapshot { summary.onSummary?(cached) }
        guard let health = health else { return }
        do {
            let coordinator = ActivitySyncCoordinator(editor: store, health: health,
                                                       service: APIActivityRepository(client: client),
                                                       installationID: try InstallationIdentity.load(disk: disk))
            activitySync = coordinator
            expeditions?.deactivate()
            let expedition = ExpeditionCoordinator(client: client, user: store.profile.userId,
                disk: disk, health: health, activity: coordinator, collection: collection)
            expeditions = expedition
            expeditionUpdates = expedition.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            coordinator.onExpeditionRefresh = { [weak expedition] in
                Task { await expedition?.recoverEvidence() }
            }
            if visitorsEnabled {
                coordinator.onAccountProgression = { [weak summary] progression, wallet in
                    summary?.receive(progression: progression, wallet: wallet)
                }
            }
            coordinator.onConfirmedGrowth = { [weak discovery = collection?.discovery] in discovery?.invalidate() }
            syncUpdates = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            store.prepareMembershipChange = { [weak coordinator] in
                guard let coordinator = coordinator else { return false }
                return await coordinator.synchronize(beforeMembershipChange: true)
            }
            store.reconcileActivity = { [weak coordinator] in _ = await coordinator?.synchronize() }
        } catch {
            store.activityBlocked = true
            PlayerMessage.recordFailure("Activity", error, scope: store.diagnosticScope)
            status = "Activity couldn’t start on this iPhone. Activity and editing are paused; reconnect to try again."
        }
    }

    func createAccount(username: String, displayName: String, assets: any AssetCatalogProviding) async {
        if authentication != nil {
            await createManagedAccount(username: username, displayName: displayName, assets: assets)
            return
        }
        #if DEBUG || INTERNAL_TOOLS
        guard !busy, let client = pendingClient, let credential = pendingCredential else { return }
        connecting = true
        let key = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let kind = "registration-" + DevelopmentCredential.fingerprint(credential)
        do {
            // Scope pre-account provisioning by a digest of the credential. It
            // contains no token on disk and is also recoverable with a fresh token:
            // /me discovers a previously committed account before provisioning.
            let request: RegisterAccountRequest
            if let saved = try disk.load(RegisterAccountRequest.self, kind: kind, server: client.baseURL.absoluteString, user: key) {
                request = saved
            } else {
                request = RegisterAccountRequest(requestId: UUID(), username: username, displayName: displayName,
                                                  gameTimezone: TimeZone.current.identifier)
                try disk.save(request, kind: kind, server: client.baseURL.absoluteString, user: key)
            }
            let _: APIAccount = try await client.request("v1/accounts", method: "POST", body: ActivityWire.encoder().encode(request))
            try disk.remove(kind: kind, server: client.baseURL.absoluteString, user: key)
            connecting = false
            await connect(url: client.baseURL.absoluteString, token: credential, assets: assets)
        } catch {
            if let error = error as? APIError, (400..<500).contains(error.status),
               ![401, 408, 429].contains(error.status), error.code != "idempotency_conflict" {
                do { try disk.remove(kind: kind, server: client.baseURL.absoluteString, user: key) }
                catch {
                    connecting = false
                    status = "The rejected account request could not be cleared. Reconnect before trying again."
                    return
                }
            }
            connecting = false
            PlayerMessage.recordFailure("Account creation", error)
            status = PlayerMessage.failure(error, fallback: "Account creation wasn’t confirmed. Check your details and try again; your saved request is retained.")
        }
        #endif
    }

    private func createManagedAccount(username: String, displayName: String, assets: any AssetCatalogProviding) async {
        guard !busy, let identity = pendingIdentity, let client = pendingClient,
              authentication?.user?.identity == identity else { return }
        connecting = true
        let operation = managedGeneration
        let user = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let kind = "registration-" + identity.storageScope
        do {
            let request: RegisterAccountRequest
            if let saved = try disk.load(RegisterAccountRequest.self, kind: kind, server: client.baseURL.absoluteString, user: user) {
                request = saved
            } else {
                request = RegisterAccountRequest(requestId: UUID(), username: username, displayName: displayName,
                                                 gameTimezone: TimeZone.current.identifier)
                try disk.save(request, kind: kind, server: client.baseURL.absoluteString, user: user)
            }
            let _: APIAccount = try await client.request("v1/accounts", method: "POST", body: ActivityWire.encoder().encode(request))
            guard managedGeneration == operation else { return }
            try disk.remove(kind: kind, server: client.baseURL.absoluteString, user: user)
            connecting = false
            await connectManaged(assets: assets)
        } catch {
            guard managedGeneration == operation else { return }
            if let error = error as? APIError, (400..<500).contains(error.status),
               ![401, 408, 429].contains(error.status), error.code != "idempotency_conflict" {
                do { try disk.remove(kind: kind, server: client.baseURL.absoluteString, user: user) }
                catch { status = "The rejected account request could not be cleared. Retry after checking device storage."; connecting = false; return }
            }
            connecting = false
            PlayerMessage.recordFailure("Account creation", error)
            status = PlayerMessage.failure(error, fallback: "Account creation wasn’t confirmed. Check your details and try again; your saved request is retained.")
        }
    }

    func disconnect() {
        #if DEBUG || INTERNAL_TOOLS
        guard authentication == nil else { return }
        guard !busy else { return }
        do {
            accountSummary?.deactivate(); accountSummary = nil; accountSummaryUpdates = nil; clearLevelUps()
            collection?.deactivate(); collection = nil; collectionUpdates = nil
            visitors?.deactivate(); visitors = nil; visitorUpdates = nil
            try DevelopmentCredential.remove()
            activitySync?.deactivate(); activitySync = nil
            expeditions?.deactivate(); expeditions = nil; expeditionUpdates = nil
            editor?.endEditing(); editor = nil
            syncUpdates = nil; editorUpdates = nil
            defaults.removeObject(forKey: Self.urlKey); savedURL = ""
            defaults.removeObject(forKey: "development.gardenAPI.profile.v1")
            pendingClient = nil; pendingCredential = nil; accountRequired = false
            status = "Disconnected. Unresolved saves are retained for their original account and server."
        } catch { status = error.localizedDescription }
        #endif
    }
}
