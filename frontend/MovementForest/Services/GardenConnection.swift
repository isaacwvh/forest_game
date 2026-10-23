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
    let authentication: AuthenticationStore?
    let configurationIssue: String?
    @Published private(set) var editor: GardenEditorStore?
    @Published private(set) var activitySync: ActivitySyncCoordinator?
    @Published private(set) var visitors: VisitorCoordinator?
    @Published private(set) var collection: CollectionCoordinator?
    @Published private(set) var accountRequired = false
    @Published private(set) var connecting = false
    @Published private(set) var status: String?
    @Published private(set) var savedURL: String
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
    private var authUpdates: AnyCancellable?
    private var managedTokens: ScopedAuthTokenProvider?
    private var managedProfileVerified = false
    private var managedGeneration = UUID()
    private var pendingIdentity: AuthIdentity?
    private static let urlKey = "development.gardenAPI.url.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuredAuth: AuthenticationStore?
        let issue: String?
        let initialURL: String
        do {
            if let configuration = try AuthConfiguration.load() {
                configuredAuth = AuthenticationStore(configuration: configuration, service: SupabaseAuthService(configuration: configuration))
                initialURL = configuration.apiURL.absoluteString
            } else { configuredAuth = nil; initialURL = "" }
            issue = nil
        } catch { configuredAuth = nil; issue = error.localizedDescription; initialURL = "" }
        authentication = configuredAuth; configurationIssue = issue; savedURL = initialURL
        #if DEBUG
        if authentication == nil && configurationIssue == nil { savedURL = defaults.string(forKey: Self.urlKey) ?? "" }
        #endif
    }

    func configureHealth(_ health: ActivityStore) { self.health = health }
    var busy: Bool { connecting || editor?.connectionBusy == true || activitySync?.busy == true }

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
                guard authentication.user != nil, !authentication.recoveringPassword else { return }
                Task { await self.connectManaged(assets: assets) }
            }
            authentication.start()
            await connectManaged(assets: assets, restoreCache: true)
            return
        }
        guard configurationIssue == nil else { status = configurationIssue; return }
        #if DEBUG
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
                if editor?.showingCached == true, let activitySync = activitySync {
                    _ = await activitySync.synchronize()
                }
            }
        } catch { status = error.localizedDescription }
        #endif
    }

    func connect(url: String, token: String, assets: any AssetCatalogProviding) async {
        #if DEBUG
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
            if let activitySync = activitySync { _ = await activitySync.synchronize() }
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
        collection?.deactivate(); collection = nil; collectionUpdates = nil
        visitors?.deactivate(); visitors = nil; visitorUpdates = nil
        managedGeneration = UUID(); managedTokens?.invalidate(); managedTokens = nil
        managedProfileVerified = false
        activitySync?.deactivate(); activitySync = nil
        editor?.deactivate(); editor = nil
        editorUpdates = nil; syncUpdates = nil
        pendingIdentity = nil; pendingClient = nil; pendingCredential = nil
        accountRequired = false; connecting = false
    }

    func connectManaged(assets: any AssetCatalogProviding, restoreCache: Bool = false) async {
        guard let auth = authentication, auth.user != nil, !auth.recoveringPassword, !connecting else { return }
        if let tokens = managedTokens, (try? tokens.validate()) != nil,
           tokens.identity == auth.user?.identity, editor?.isActive == true,
           managedProfileVerified, !restoreCache { return }
        let operation = UUID(); managedGeneration = operation
        connecting = true; status = "Loading your account…"
        defer { if managedGeneration == operation { connecting = false } }
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
                // No queued mutations are sent until /me confirms the game identity.
            }
            let profile: APIProfile
            do { profile = try await repository.profile() }
            catch let error as APIError where error.code == "account_required" {
                guard managedGeneration == operation else { return }
                editor?.deactivate(); editor = nil
                defaults.removeObject(forKey: "supabase.gameProfile.v1")
                pendingIdentity = tokens.identity; pendingClient = client; accountRequired = true
                status = "Choose your game username and display name."
                return
            }
            try tokens.validate()
            guard managedGeneration == operation else { return }
            defaults.set(try JSONEncoder().encode(ManagedProfile(identity: tokens.identity, server: repository.serverID, profile: profile)),
                         forKey: "supabase.gameProfile.v1")
            accountRequired = false; pendingIdentity = nil; pendingClient = nil
            managedProfileVerified = true
            activitySync?.deactivate(); editor?.deactivate()
            let store = GardenEditorStore(profile: profile, service: repository, assets: assets, cache: disk)
            editor = store
            await store.start()
            guard managedGeneration == operation else { store.deactivate(); return }
            installActivity(client: client, store: store)
            if let activitySync = activitySync { _ = await activitySync.synchronize() }
            guard managedGeneration == operation else { return }
            status = "Signed in as \(profile.displayName)."
        } catch {
            guard managedGeneration == operation else { return }
            status = "Account connection paused. \(error.localizedDescription) Saved requests are retained."
        }
    }

    func signOut() async {
        await visitors?.pause()
        if let authentication = authentication {
            guard !authentication.busy else { return }
            detachManaged()
            defaults.removeObject(forKey: "supabase.gameProfile.v1")
            await authentication.signOut()
        } else { disconnect() }
    }

    private func installActivity(client: APIClient, store: GardenEditorStore, visitorsEnabled: Bool = true) {
        collection?.deactivate(); collection = nil; collectionUpdates = nil
        if visitorsEnabled {
            let collection = CollectionCoordinator(userID: store.profile.userId, service: APICollectionRepository(client: client))
            self.collection = collection
            collectionUpdates = collection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            collection.onPlantAwarded = { [weak store] in await store?.refresh() }
        }
        editorUpdates = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        visitors?.deactivate(); visitors = nil; visitorUpdates = nil
        if visitorsEnabled {
            do {
                let visitor = VisitorCoordinator(userID: store.profile.userId,
                    installationID: try InstallationIdentity.load(disk: disk), service: APIVisitorRepository(client: client))
                visitors = visitor
                visitor.onWallet = { [weak collection = self.collection] balance, version in
                    collection?.applyWallet(balance, version: version)
                }
                collection?.onWallet = { [weak visitor] balance, version in visitor?.applyWallet(balance, version: version) }
                visitorUpdates = visitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                visitor.start()
            } catch { status = "Visitors paused: the installation identity could not be read." }
        }
        guard let health = health else { return }
        do {
            let coordinator = ActivitySyncCoordinator(editor: store, health: health,
                                                       service: APIActivityRepository(client: client),
                                                       installationID: try InstallationIdentity.load(disk: disk))
            activitySync = coordinator
            syncUpdates = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            store.prepareMembershipChange = { [weak coordinator] in
                guard let coordinator = coordinator else { return false }
                return await coordinator.synchronize(beforeMembershipChange: true)
            }
            store.reconcileActivity = { [weak coordinator] in _ = await coordinator?.synchronize() }
        } catch {
            store.activityBlocked = true
            status = "The installation identity could not be read. Activity and editing are paused."
        }
    }

    func createAccount(username: String, displayName: String, assets: any AssetCatalogProviding) async {
        if authentication != nil {
            await createManagedAccount(username: username, displayName: displayName, assets: assets)
            return
        }
        #if DEBUG
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
            status = "Account creation was not confirmed. \(error.localizedDescription)"
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
            status = "Account creation was not confirmed. \(error.localizedDescription) Retry preserves the original request."
        }
    }

    func disconnect() {
        #if DEBUG
        guard authentication == nil else { return }
        guard !busy else { return }
        do {
            collection?.deactivate(); collection = nil; collectionUpdates = nil
            visitors?.deactivate(); visitors = nil; visitorUpdates = nil
            try DevelopmentCredential.remove()
            activitySync?.deactivate(); activitySync = nil
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
