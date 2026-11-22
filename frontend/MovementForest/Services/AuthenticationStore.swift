import Foundation
import Combine
import CryptoKit

struct AuthIdentity: Codable, Equatable {
    let issuer: String
    let subject: UUID
    var storageScope: String {
        SHA256.hash(data: Data("\(issuer)|\(subject.uuidString.lowercased())".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AuthUserInfo: Equatable {
    let identity: AuthIdentity
    let email: String?
    let methods: [String]
    var isAnonymous: Bool = false
    var emailVerified: Bool = false
    // Presentation capability, confirmed by password setup/login. Never inferred
    // from an OAuth email or used to authorize game/API access.
    var hasEmailPassword: Bool = false
}

struct AuthAccessToken {
    let identity: AuthIdentity
    let value: String
}

enum AuthSessionEvent { case changed(AuthUserInfo?), passwordRecovery(AuthUserInfo), restoreFailed }

enum AuthEntryAction: Equatable { case restoring, retry, play, continueGarden, signIn }

struct AuthEntryPresentationState {
    private var signInCount = 0
    var hasSignIn: Bool { signInCount > 0 }
    mutating func signInChanged(_ visible: Bool) {
        signInCount = max(0, signInCount + (visible ? 1 : -1))
    }
}

@MainActor
protocol AuthenticationServing: AnyObject {
    var cachedUser: AuthUserInfo? { get }
    var onEvent: ((AuthSessionEvent) -> Void)? { get set }
    func start()
    func accessToken(refresh: Bool) async throws -> AuthAccessToken
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws -> Bool
    func resetPassword(email: String) async throws
    func resendConfirmation(email: String) async throws
    func updatePassword(_ password: String) async throws
    func updateEmail(_ email: String) async throws
    func google(link: Bool) async throws
    func apple(idToken: String, nonce: String, link: Bool) async throws
    func handleCallback(_ url: URL) async throws
    func signOut() async throws
    func signInAnonymously() async throws -> AuthUserInfo
    func stagingService() throws -> any AuthenticationServing
    func adopt(_ candidate: any AuthenticationServing) async throws
    func discard() async throws
    func refreshUser() async throws -> AuthUserInfo
    func verifyEmailChange(email: String, code: String) async throws -> AuthUserInfo
}

extension AuthenticationServing {
    func signInAnonymously() async throws -> AuthUserInfo { throw AuthenticationStore.signInRequired }
    func stagingService() throws -> any AuthenticationServing { throw AuthenticationStore.signInRequired }
    func adopt(_ candidate: any AuthenticationServing) async throws { throw AuthenticationStore.signInRequired }
    func discard() async throws { }
    func refreshUser() async throws -> AuthUserInfo { throw AuthenticationStore.signInRequired }
    func verifyEmailChange(email: String, code: String) async throws -> AuthUserInfo { throw AuthenticationStore.signInRequired }
}

@MainActor
final class AuthenticationStore: ObservableObject {
    @Published private(set) var user: AuthUserInfo?
    @Published private(set) var busy = false
    @Published private(set) var recoveringPassword = false
    @Published private(set) var message: String?
    @Published private(set) var restoring = true
    @Published private(set) var restoreUnavailable = false
    @Published private(set) var candidate: AuthenticationStore?
    @Published private(set) var hasHistory: Bool
    @Published private(set) var lastWasGuest: Bool
    @Published private(set) var emailLinkAddress: String? = nil
    private(set) var generation = UUID()
    var onSessionChange: (() -> Void)?
    let configuration: AuthConfiguration
    private let service: any AuthenticationServing
    private var started = false
    private var expectedLinkIdentity: AuthIdentity?
    private var acceptingSessionEvents = true
    private let defaults: UserDefaults
    private let historyKey: String
    private var isolated = false

    var entryAction: AuthEntryAction {
        if restoring { return .restoring }
        if restoreUnavailable { return .retry }
        if user != nil { return .continueGarden }
        return !hasHistory && configuration.guestEnabled ? .play : .signIn
    }

    init(configuration: AuthConfiguration, service: any AuthenticationServing, defaults: UserDefaults = .standard,
         isolated: Bool = false) {
        self.configuration = configuration; self.service = service
        self.isolated = isolated
        self.defaults = defaults
        let entryKey = "auth.entry.v1." + (configuration.projectURL.host ?? "auth")
        historyKey = entryKey
        let loggedOut = !isolated && defaults.bool(forKey: entryKey + ".signedOut")
        self.user = loggedOut ? nil : service.cachedUser
        acceptingSessionEvents = !loggedOut
        restoring = !loggedOut
        recoveringPassword = !isolated && !loggedOut && service.cachedUser != nil && defaults.bool(forKey: entryKey + ".recovery")
        hasHistory = defaults.bool(forKey: entryKey) || service.cachedUser != nil
        lastWasGuest = service.cachedUser?.isAnonymous ?? defaults.bool(forKey: entryKey + ".guest")
        if let identity = user?.identity {
            emailLinkAddress = defaults.string(forKey: "auth.emailLink.v1." + identity.storageScope)
        }
    }

    func start() {
        guard !started else { return }; started = true
        service.onEvent = { [weak self] event in self?.receive(event) }
        service.start()
    }

    private func receive(_ event: AuthSessionEvent) {
        guard acceptingSessionEvents else { return }
        if case .restoreFailed = event {
            restoreUnavailable = true; restoring = false
            message = "Saved sign-in unavailable. Try again."
            return
        }
        restoring = false; restoreUnavailable = false
        let next: AuthUserInfo?
        switch event {
        case .changed(let value): next = value
        case .passwordRecovery(let value):
            recoveringPassword = true; next = value
            if !isolated { defaults.set(true, forKey: historyKey + ".recovery") }
        case .restoreFailed: return
        }
        if let expected = expectedLinkIdentity, let next = next, next.identity != expected {
            user = nil; generation = UUID(); onSessionChange?()
            message = "That method belongs to another account. Sign in instead."
            return
        }
        let changed = user?.identity != next?.identity
        user = next
        if changed {
            emailLinkAddress = next.flatMap { defaults.string(forKey: "auth.emailLink.v1." + $0.identity.storageScope) }
        }
        if next == nil {
            recoveringPassword = false
            if !isolated { defaults.set(false, forKey: historyKey + ".recovery") }
        }
        if let next = next {
            lastWasGuest = next.isAnonymous
            if !isolated { defaults.set(next.isAnonymous, forKey: historyKey + ".guest") }
            rememberAccount()
        }
        if changed { generation = UUID(); onSessionChange?() }
        if recoveringPassword { onSessionChange?() }
    }

    private func rememberAccount() {
        hasHistory = true
        if !isolated {
            defaults.set(true, forKey: historyKey)
            defaults.set(false, forKey: historyKey + ".signedOut")
        }
    }

    func retryRestore() {
        guard !busy else { return }
        restoring = true; restoreUnavailable = false
        service.start()
    }

    /// Separate Keychain/PKCE context. The active account remains usable until adoption.
    func prepareCandidate() throws -> AuthenticationStore {
        if let candidate = candidate { return candidate }
        let value = AuthenticationStore(configuration: configuration, service: try service.stagingService(), defaults: defaults,
                                         isolated: true)
        candidate = value; value.start()
        return value
    }

    func createGuest() async -> Bool {
        guard configuration.guestEnabled, !busy, !restoring, !restoreUnavailable else { return false }
        var succeeded = false
        await perform {
            var target = try self.prepareCandidate()
            guard !target.restoreUnavailable else {
                throw ForestError.invalidData("Saved guest setup is unavailable. Try again.")
            }
            if target.user?.isAnonymous == false {
                try await target.service.discard(); self.candidate = nil
                target = try self.prepareCandidate()
            }
            if target.user == nil {
                // Use the completed signup result, not an initial/cache snapshot
                // that can still describe the signed-out session.
                let guest = try await target.service.signInAnonymously()
                target.receive(.changed(guest))
            }
            guard target.user?.isAnonymous == true else {
                throw ForestError.invalidData("Guest sign-in wasn’t confirmed. Try again.")
            }
            succeeded = true
        }
        return succeeded
    }

    func commitCandidate() async throws {
        guard let target = candidate, let expected = target.user?.identity else { throw Self.signInRequired }
        acceptingSessionEvents = false
        defer { acceptingSessionEvents = true }
        try await service.adopt(target.service)
        guard service.cachedUser?.identity == expected else { throw Self.signInRequired }
        candidate = nil
        recoveringPassword = false
        defaults.set(false, forKey: historyKey + ".recovery")
        acceptingSessionEvents = true
        receive(.changed(service.cachedUser))
    }

    func cancelCandidate() async {
        guard let target = candidate, !target.busy, !busy else { return }
        do { try await target.service.discard(); candidate = nil }
        catch { message = "Sign-in couldn’t close. Try again." }
    }

    var stagedCallbackPending: Bool { defaults.bool(forKey: historyKey + ".stagedCallback") }
    func markStagedCallback(_ pending: Bool) { defaults.set(pending, forKey: historyKey + ".stagedCallback") }

    func scopedTokens() throws -> ScopedAuthTokenProvider {
        guard let identity = user?.identity, !recoveringPassword else { throw Self.signInRequired }
        return ScopedAuthTokenProvider(store: self, identity: identity, generation: generation)
    }

    fileprivate func token(identity: AuthIdentity, generation: UUID, refresh: Bool) async throws -> String {
        try validate(identity: identity, generation: generation)
        let token = try await service.accessToken(refresh: refresh)
        try validate(identity: identity, generation: generation)
        guard token.identity == identity else { throw Self.signInRequired }
        return token.value
    }

    fileprivate func validate(identity: AuthIdentity, generation: UUID) throws {
        guard self.generation == generation, user?.identity == identity, !recoveringPassword else { throw Self.signInRequired }
    }
    static var signInRequired: APIError { APIError(status: 401, code: "session_required", message: "Sign in again to resume your saved requests.") }

    private func perform(_ action: () async throws -> Void, success: String? = nil) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false; expectedLinkIdentity = nil }
        do { try await action(); if let success = success { message = success } }
        catch is CancellationError { message = "Sign-in cancelled." }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func signIn(email: String, password: String) async -> Bool {
        var succeeded = false
        await perform {
            self.acceptingSessionEvents = true
            try await self.service.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            succeeded = true
        }
        return succeeded
    }
    func signUp(email: String, password: String) async {
        await perform {
            self.acceptingSessionEvents = true
            let signedIn = try await self.service.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            self.message = signedIn ? "Signed in. Create your garden." : "Check your email, then sign in."
        }
    }
    func resetPassword(email: String) async {
        await perform({ try await self.service.resetPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) },
                      success: "Check your email for a reset link. Open it on this iPhone.")
    }
    func resendConfirmation(email: String) async {
        await perform({ try await self.service.resendConfirmation(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) },
                      success: "Check your email. Open the link on this iPhone.")
    }
    @discardableResult
    func updatePassword(_ password: String) async -> Bool {
        guard let expected = user?.identity else { return false }
        guard recoveringPassword || (user?.isAnonymous == false && user?.emailVerified == true) else {
            message = "Verify your email first."; return false
        }
        guard recoveringPassword || emailLinkAddress == nil || emailLinkVerified else {
            message = "Verify your email first."; return false
        }
        var succeeded = false
        await perform {
            self.expectedLinkIdentity = expected
            try await self.service.updatePassword(password)
            guard self.user?.identity == expected else { throw Self.signInRequired }
            self.user?.hasEmailPassword = true
            self.setEmailLinkAddress(nil, identity: expected)
            let wasRecovering = self.recoveringPassword
            self.recoveringPassword = false
            self.defaults.set(false, forKey: self.historyKey + ".recovery")
            self.message = "Password saved."
            succeeded = true
            if wasRecovering { self.onSessionChange?() }
        }
        return succeeded
    }

    var emailLinkVerified: Bool {
        guard let address = emailLinkAddress, let user = user else { return false }
        return !user.isAnonymous && user.emailVerified && user.email?.lowercased() == address.lowercased()
    }

    var needsGuestExitWarning: Bool {
        user?.isAnonymous == true || (emailLinkAddress != nil && user?.hasEmailPassword != true &&
            user?.methods.allSatisfy { $0 == "email" } == true)
    }

    private func setEmailLinkAddress(_ address: String?, identity: AuthIdentity) {
        defaults.set(address, forKey: "auth.emailLink.v1." + identity.storageScope)
        if user?.identity == identity { emailLinkAddress = address }
    }

    func linkEmail(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected = user?.identity, !busy, !recoveringPassword,
              address.contains("@"), address.count <= 254 else { return }
        await perform {
            self.expectedLinkIdentity = expected
            // Retain non-secret intent even if delivery has an uncertain outcome.
            self.setEmailLinkAddress(address, identity: expected)
            if self.user?.email?.lowercased() != address.lowercased() || self.user?.emailVerified != true {
                try await self.service.updateEmail(address)
                let updated = try await self.service.refreshUser()
                guard updated.identity == expected else { throw Self.signInRequired }
                self.receive(.changed(updated))
            }
            self.message = self.emailLinkVerified ? nil : "Check your email."
        }
    }

    func verifyLinkedEmail(code: String) async {
        guard let expected = user?.identity, let address = emailLinkAddress else { return }
        await perform {
            self.expectedLinkIdentity = expected
            let updated = try await self.service.verifyEmailChange(email: address, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            guard updated.identity == expected else { throw Self.signInRequired }
            self.receive(.changed(updated))
            self.message = self.emailLinkVerified ? nil : "Email verification is still pending."
        }
    }

    func refreshLinkedEmail() async {
        guard emailLinkAddress != nil, let expected = user?.identity else { return }
        await perform {
            self.expectedLinkIdentity = expected
            let updated = try await self.service.refreshUser()
            guard updated.identity == expected else { throw Self.signInRequired }
            self.receive(.changed(updated))
            if !self.emailLinkVerified { self.message = "Email verification is still pending." }
        }
    }
    func updateEmail(_ email: String) async {
        await perform({ try await self.service.updateEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) },
                      success: "Check your new email to confirm the change.")
    }
    @discardableResult
    func google(link: Bool) async -> Bool {
        guard configuration.googleEnabled, !link || user != nil else { return false }
        var succeeded = false
        await perform {
            if !link { self.acceptingSessionEvents = true }
            self.expectedLinkIdentity = link ? self.user?.identity : nil
            try await self.service.google(link: link)
            if link, self.user?.identity != self.expectedLinkIdentity { throw Self.signInRequired }
            self.message = link ? "Google linked to this account." : "Signed in with Google."
            succeeded = true
        }
        return succeeded
    }
    func apple(idToken: String, nonce: String, link: Bool) async {
        guard configuration.appleEnabled, !link || user != nil else { return }
        await perform {
            if !link { self.acceptingSessionEvents = true }
            self.expectedLinkIdentity = link ? self.user?.identity : nil
            try await self.service.apple(idToken: idToken, nonce: nonce, link: link)
            if link, self.user?.identity != self.expectedLinkIdentity { throw Self.signInRequired }
            self.message = link ? "Apple linked to this account." : "Signed in with Apple."
        }
    }
    func report(_ message: String) { self.message = message }

    @discardableResult
    func handleCallback(_ url: URL) async -> Bool {
        guard configuration.accepts(url), !busy else { return false }
        start()
        acceptingSessionEvents = true
        busy = true; message = nil
        defer { busy = false }
        let previousRecovery = recoveringPassword
        // Suspend game access before the SDK emits SIGNED_IN for recovery.
        if url.path == configuration.recoveryURL.path {
            recoveringPassword = true
            if !isolated { defaults.set(true, forKey: historyKey + ".recovery") }
            onSessionChange?()
        }
        do {
            try await service.handleCallback(url)
            message = recoveringPassword ? "Choose your new password." : "Sign-in confirmed."
            return true
        } catch {
            recoveringPassword = previousRecovery
            if !isolated { defaults.set(previousRecovery, forKey: historyKey + ".recovery") }
            onSessionChange?()
            message = "Link expired or unavailable. Request a new email."
            return false
        }
    }

    func signOut() async {
        guard !busy else { return }
        rememberAccount()
        defaults.set(true, forKey: historyKey + ".signedOut")
        defaults.set(false, forKey: historyKey + ".recovery")
        busy = true; acceptingSessionEvents = false; generation = UUID(); user = nil; recoveringPassword = false
        onSessionChange?() // Revoke game access immediately, including offline/in-flight work.
        defer { busy = false }
        do { try await service.signOut(); message = "Signed out." }
        catch { message = "Signed out on this iPhone." }
    }
}

@MainActor
final class ScopedAuthTokenProvider: TokenProviding {
    private let store: AuthenticationStore
    let identity: AuthIdentity
    private let generation: UUID
    private var active = true
    init(store: AuthenticationStore, identity: AuthIdentity, generation: UUID) {
        self.store = store; self.identity = identity; self.generation = generation
    }
    func invalidate() { active = false }
    func validate() throws {
        guard active else { throw AuthenticationStore.signInRequired }
        try store.validate(identity: identity, generation: generation)
    }
    func token() async throws -> String { try await fetch(refresh: false) }
    func refreshedToken() async throws -> String { try await fetch(refresh: true) }
    private func fetch(refresh: Bool) async throws -> String {
        try validate()
        let value = try await store.token(identity: identity, generation: generation, refresh: refresh)
        try validate(); return value
    }
}
