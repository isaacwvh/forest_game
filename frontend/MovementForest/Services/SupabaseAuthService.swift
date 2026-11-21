import Foundation
import Auth
import AuthenticationServices
import UIKit
import CryptoKit
import Security

/// Only this adapter depends on the SDK. Credentials/sessions remain in its
/// Keychain store; game queues contain no access or refresh tokens.
@MainActor
final class SupabaseAuthService: AuthenticationServing {
    private var client: AuthClient
    private let configuration: AuthConfiguration
    private let storage: SessionKeychainStorage
    private var lease: AuthStorageLease
    private let storageKey: String
    private let staged: Bool
    private var epoch = UUID()
    private var linking = false
    private var handoffInProgress = false
    private var tokenOperation: Task<Session, Error>?
    private var tokenOperationID = UUID()
    private var tokenOperationForcesRefresh = false
    private let browser = AuthBrowser()
    private var observer: Task<Void, Never>?
    var onEvent: ((AuthSessionEvent) -> Void)?

    init(configuration: AuthConfiguration, staged: Bool = false) {
        self.configuration = configuration
        self.staged = staged
        let key = "movement-forest-\(configuration.projectURL.host ?? "auth")"
        let localStorage = SessionKeychainStorage(service: "\(Bundle.main.bundleIdentifier ?? "MovementForest").SupabaseAuth" + (staged ? ".Staging" : ""))
        let initialLease = AuthStorageLease(storage: localStorage)
        storageKey = key; storage = localStorage; lease = initialLease
        client = Self.makeClient(configuration, key: key, storage: initialLease, staged: staged)
    }

    private static func makeClient(_ configuration: AuthConfiguration, key: String,
                                   storage: AuthStorageLease, staged: Bool) -> AuthClient {
        AuthClient(configuration: .init(
            url: configuration.projectURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": configuration.publishableKey], flowType: .pkce,
            redirectToURL: configuration.callbackURL,
            storageKey: key, localStorage: storage, autoRefreshToken: false,
            emitLocalSessionAsInitialSession: true))
    }
    deinit { observer?.cancel() }

    var cachedUser: AuthUserInfo? { client.currentSession.map { info($0.user) } }
    private func info(_ user: Auth.User) -> AuthUserInfo {
        AuthUserInfo(identity: AuthIdentity(issuer: configuration.issuer, subject: user.id), email: user.email,
                     methods: Array(Set((user.identities ?? []).map(\.provider))).sorted(), isAnonymous: user.isAnonymous)
    }
    func start() {
        do {
            // SDK reads swallow storage errors. Fail closed while Keychain is locked/corrupt.
            if let data = try storage.retrieve(key: storageKey), cachedUser == nil, !data.isEmpty {
                onEvent?(.restoreFailed); return
            }
        } catch { onEvent?(.restoreFailed); return }
        guard observer == nil else { onEvent?(.changed(cachedUser)); return }
        let expectedEpoch = epoch
        observer = Task { [weak self, client] in
            for await (event, session) in client.authStateChanges {
                guard !Task.isCancelled, let self = self, self.epoch == expectedEpoch else { return }
                guard !self.linking else { continue }
                if event == .passwordRecovery, let session = session {
                    self.onEvent?(.passwordRecovery(self.info(session.user)))
                } else { self.onEvent?(.changed(self.cachedUser)) }
            }
        }
    }

    func accessToken(refresh: Bool) async throws -> AuthAccessToken {
        guard !handoffInProgress, !linking else { throw CancellationError() }
        if refresh, let pending = tokenOperation, !tokenOperationForcesRefresh {
            let pendingID = tokenOperationID
            _ = try? await pending.value
            if tokenOperationID == pendingID { tokenOperation = nil }
            return try await accessToken(refresh: true)
        }
        let expectedEpoch = epoch
        let operation: Task<Session, Error>
        let operationID: UUID
        if let pending = tokenOperation {
            operation = pending; operationID = tokenOperationID
        } else {
            operationID = UUID(); tokenOperationID = operationID
            tokenOperationForcesRefresh = refresh
            operation = Task { [client] in
                if refresh { return try await client.refreshSession() }
                return try await client.session
            }
            tokenOperation = operation
        }
        defer { if tokenOperationID == operationID { tokenOperation = nil } }
        do {
            let session = try await operation.value
            guard epoch == expectedEpoch else { throw AuthenticationStore.signInRequired }
            try verifySaved(session)
            return AuthAccessToken(identity: info(session.user).identity, value: session.accessToken)
        } catch let error as AuthError {
            guard epoch == expectedEpoch else { throw AuthenticationStore.signInRequired }
            let terminal = ["session_not_found", "refresh_token_not_found", "refresh_token_already_used", "user_banned", "user_not_found"]
            if terminal.contains(error.errorCode.rawValue) {
                onEvent?(.changed(nil)); throw AuthenticationStore.signInRequired
            }
            throw publicError(error)
        }
    }

    private func verifySaved(_ session: Session) throws {
        guard let data = try storage.retrieve(key: storageKey),
              let saved = try? JSONDecoder().decode(Session.self, from: data),
              saved.user.id == session.user.id, saved.refreshToken == session.refreshToken else {
            throw ForestError.invalidData("Sign-in couldn’t be saved. Try again.")
        }
    }

    func signInAnonymously() async throws -> AuthUserInfo {
        guard staged else { throw AuthenticationStore.signInRequired }
        do {
            let session = try await client.signInAnonymously()
            try verifySaved(session)
            let guest = info(session.user)
            onEvent?(.changed(guest))
            return guest
        } catch { throw publicError(error) }
    }

    func stagingService() throws -> any AuthenticationServing {
        let target = SupabaseAuthService(configuration: configuration, staged: true)
        // A failed cleanup must not later resurrect an already adopted stage as
        // a supposedly new guest. Only the non-secret committed subject is noted.
        if let subject = target.cachedUser?.identity.subject.uuidString,
           UserDefaults.standard.string(forKey: storageKey + ".adoptedStage") == subject {
            try target.storage.remove(key: storageKey)
        }
        return target
    }

    func adopt(_ candidate: any AuthenticationServing) async throws {
        guard let target = candidate as? SupabaseAuthService, target.staged,
              target.configuration.projectURL == configuration.projectURL,
              let session = target.client.currentSession else { throw AuthenticationStore.signInRequired }
        try target.verifySaved(session)
        let data = try JSONEncoder().encode(session)
        handoffInProgress = true
        defer { handoffInProgress = false }
        // All refreshes are demand-driven through tokenOperation. Wait for the
        // sole writer before taking rollback bytes, including its rotated token.
        if let pending = tokenOperation { _ = try? await pending.value }
        await target.client.stopAutoRefresh()
        await client.stopAutoRefresh()
        // Revoke old storage writers before replacing one atomic Keychain item. No network
        // request or refresh is required to adopt an already verified staged session.
        let previous = try lease.snapshotAndRevoke(key: storageKey)
        target.lease.revoke()
        observer?.cancel(); observer = nil; epoch = UUID()
        do {
            try storage.store(key: storageKey, value: data)
            guard try storage.retrieve(key: storageKey) == data else { throw AuthenticationStore.signInRequired }
        } catch {
            if let previous = previous { try storage.store(key: storageKey, value: previous) }
            else { try storage.remove(key: storageKey) }
            resetClient(); target.resetClient()
            throw error
        }
        resetClient()
        UserDefaults.standard.set(session.user.id.uuidString, forKey: storageKey + ".adoptedStage")
        // Do not call server signOut: those credentials now belong to the active client.
        try? target.storage.remove(key: storageKey)
        target.observer?.cancel(); target.observer = nil
    }

    private func resetClient() {
        tokenOperation = nil; tokenOperationID = UUID()
        lease = AuthStorageLease(storage: storage)
        client = Self.makeClient(configuration, key: storageKey, storage: lease, staged: staged)
        start()
    }

    func discard() async throws {
        await client.stopAutoRefresh()
        lease.revoke(); observer?.cancel(); observer = nil; epoch = UUID()
        try storage.remove(key: storageKey)
    }

    func signIn(email: String, password: String) async throws {
        do { let session = try await client.signIn(email: email, password: password); onEvent?(.changed(info(session.user))) }
        catch { throw publicError(error) }
    }
    func signUp(email: String, password: String) async throws -> Bool {
        do {
            let result = try await client.signUp(email: email, password: password, redirectTo: configuration.callbackURL)
            if let session = result.session { onEvent?(.changed(info(session.user))) }
            return result.session != nil
        } catch { throw publicError(error) }
    }
    func resetPassword(email: String) async throws {
        do { try await client.resetPasswordForEmail(email, redirectTo: configuration.recoveryURL) }
        catch { throw publicError(error) }
    }
    func resendConfirmation(email: String) async throws {
        do { try await client.resend(email: email, type: .signup, emailRedirectTo: configuration.callbackURL) }
        catch { throw publicError(error) }
    }
    func updatePassword(_ password: String) async throws {
        do { _ = try await client.update(user: UserAttributes(password: password)) }
        catch { throw publicError(error) }
    }
    func updateEmail(_ email: String) async throws {
        do { _ = try await client.update(user: UserAttributes(email: email), redirectTo: configuration.callbackURL) }
        catch { throw publicError(error) }
    }

    func google(link: Bool) async throws {
        linking = link
        defer {
            linking = false
            if link { try? storage.remove(key: storageKey + ".link-backup") }
        }
        if link, let pending = tokenOperation { _ = try? await pending.value }
        if link { try verifySaved(try await client.session) }
        let original = try storage.retrieve(key: storageKey)
        let previous = cachedUser?.identity
        if link, let original = original {
            try storage.store(key: storageKey + ".link-backup", value: original)
        }
        do {
            let session: Session
            if link {
                let result = try await client.getLinkIdentityURL(provider: .google, redirectTo: configuration.callbackURL)
                let url = try await browser.open(result.url, callback: configuration.callbackURL)
                session = try await client.session(from: url)
                guard info(session.user).identity == previous else {
                    await client.stopAutoRefresh(); lease.revoke()
                    observer?.cancel(); observer = nil; epoch = UUID()
                    if let original = original { try storage.store(key: storageKey, value: original) }
                    resetClient()
                    throw AuthenticationStore.signInRequired
                }
            } else {
                session = try await client.signInWithOAuth(provider: .google, redirectTo: configuration.callbackURL,
                    launchFlow: { [browser, configuration] url in try await browser.open(url, callback: configuration.callbackURL) })
            }
            try verifySaved(session)
            if let returned = browser.lastReturnedURL { AuthCallbackReceipts.remember(returned) }
            onEvent?(.changed(info(session.user)))
        } catch {
            if link, cachedUser?.identity != previous, let original = original {
                await client.stopAutoRefresh(); lease.revoke()
                observer?.cancel(); observer = nil; epoch = UUID()
                try storage.store(key: storageKey, value: original)
                resetClient()
            }
            throw publicError(error)
        }
    }

    func apple(idToken: String, nonce: String, link: Bool) async throws {
        do {
            let previous = cachedUser?.identity
            let credentials = OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            let session: Session
            if link {
                session = try await client.linkIdentityWithIdToken(credentials: credentials)
                guard info(session.user).identity == previous else {
                    try? await client.signOut(scope: .local)
                    throw AuthenticationStore.signInRequired
                }
            } else { session = try await client.signInWithIdToken(credentials: credentials) }
            onEvent?(.changed(info(session.user)))
        } catch { throw publicError(error) }
    }

    func handleCallback(_ url: URL) async throws {
        guard configuration.accepts(url), !browser.active else { return }
        do {
            let backup = try storage.retrieve(key: storageKey + ".link-backup")
            let expected = backup.flatMap { try? JSONDecoder().decode(Session.self, from: $0).user.id }
            linking = expected != nil
            defer { linking = false }
            let session = try await client.session(from: url)
            if let expected = expected, session.user.id != expected, let backup = backup {
                await client.stopAutoRefresh(); lease.revoke()
                observer?.cancel(); observer = nil; epoch = UUID()
                try storage.store(key: storageKey, value: backup); resetClient()
                throw AuthenticationStore.signInRequired
            }
            try verifySaved(session)
            try storage.remove(key: storageKey + ".link-backup")
            AuthCallbackReceipts.remember(url)
            onEvent?(.changed(info(session.user)))
        }
        catch { throw publicError(error) }
    }
    func signOut() async throws {
        defer { onEvent?(.changed(nil)) }
        do { try await client.signOut(scope: .local) }
        catch { try storage.remove(key: storageKey); throw error }
        try storage.remove(key: storageKey)
    }

    private func publicError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? AuthError {
            DiagnosticHistory.shared.record("Authentication", "failed: \(error.errorCode.rawValue)")
            let message: String
            switch error.errorCode.rawValue {
            case "invalid_credentials": message = "Check your email and password and try again."
            case "email_not_confirmed": message = "Confirm your email before signing in. You can resend confirmation below."
            case "weak_password": message = "Choose a stronger password and try again."
            case "over_email_send_rate_limit", "over_request_rate_limit": message = "Too many attempts. Wait a little and try again."
            case "identity_already_exists": message = "That sign-in belongs to another account. Use Sign in another way."
            case "email_exists": message = "That email belongs to another account. Sign in instead."
            case "anonymous_provider_disabled": message = "Guest play is unavailable. Try signing in."
            case "manual_linking_disabled": message = "Linking another sign-in method is unavailable in this version."
            default: message = "Sign-in couldn’t finish. Check your connection and try again."
            }
            return ForestError.invalidData(message)
        }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return CancellationError() }
        PlayerMessage.recordFailure("Authentication", error)
        return ForestError.invalidData(PlayerMessage.failure(error, fallback: "Sign-in couldn’t finish. Please try again."))
    }
}

/// A retired SDK client can finish an in-flight request, but cannot overwrite the
/// newly adopted account's Keychain session. Each auth context has its own lease.
private final class AuthStorageLease: AuthLocalStorage, @unchecked Sendable {
    private let storage: SessionKeychainStorage
    private let lock = NSLock()
    private var active = true
    init(storage: SessionKeychainStorage) { self.storage = storage }
    func revoke() { lock.lock(); defer { lock.unlock() }; active = false }
    func snapshotAndRevoke(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let saved = try storage.retrieve(key: key)
        active = false
        return saved
    }
    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        try storage.store(key: key, value: value)
    }
    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        return try storage.retrieve(key: key)
    }
    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        try storage.remove(key: key)
    }
}

/// Keep the SDK's existing service/account names and write format. Its pinned
/// Keychain reader/deleter throws for absent items; absence is normal for a fresh
/// guest context, a consumed link backup and an already signed-out session.
struct SessionKeychainStorage: AuthLocalStorage {
    let service: String
    func store(key: String, value: Data) throws {
        try KeychainLocalStorage(service: service).store(key: key, value: value)
    }
    func retrieve(key: String) throws -> Data? {
        var attributes = query(key: key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return data
    }
    func remove(key: String) throws {
        let status = SecItemDelete(query(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
    private func query(key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}

@MainActor
private final class AuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private(set) var lastReturnedURL: URL?
    var active: Bool { session != nil }
    func open(_ url: URL, callback: URL) async throws -> URL {
        guard session == nil else { throw CancellationError() }
        lastReturnedURL = nil
        return try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: callback.scheme) { [weak self] result, error in
                Task { @MainActor in
                    self?.session = nil
                    if let error = error { continuation.resume(throwing: error) }
                    else if let result = result, result.scheme == callback.scheme,
                            result.host == callback.host, result.path == callback.path {
                        self?.lastReturnedURL = result
                        continuation.resume(returning: result)
                    } else { continuation.resume(throwing: CancellationError()) }
                }
            }
            session = web; web.presentationContextProvider = self
            if !web.start() { session = nil; continuation.resume(throwing: CancellationError()) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// Only non-secret fingerprints of successfully consumed callback URLs persist.
@MainActor
enum AuthCallbackReceipts {
    private static let key = "auth.consumedCallbacks.v1"
    private static func fingerprint(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func contains(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(fingerprint(url))
    }
    static func remember(_ url: URL) {
        let value = fingerprint(url)
        var saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        saved.removeAll { $0 == value }; saved.append(value)
        UserDefaults.standard.set(Array(saved.suffix(8)), forKey: key)
    }
}
