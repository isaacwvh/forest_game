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
}

struct AuthAccessToken {
    let identity: AuthIdentity
    let value: String
}

enum AuthSessionEvent { case changed(AuthUserInfo?), passwordRecovery(AuthUserInfo) }

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
}

@MainActor
final class AuthenticationStore: ObservableObject {
    @Published private(set) var user: AuthUserInfo?
    @Published private(set) var busy = false
    @Published private(set) var recoveringPassword = false
    @Published private(set) var message: String?
    private(set) var generation = UUID()
    var onSessionChange: (() -> Void)?
    let configuration: AuthConfiguration
    private let service: any AuthenticationServing
    private var started = false
    private var expectedLinkIdentity: AuthIdentity?
    private var acceptingSessionEvents = true

    init(configuration: AuthConfiguration, service: any AuthenticationServing) {
        self.configuration = configuration; self.service = service
        self.user = service.cachedUser
    }

    func start() {
        guard !started else { return }; started = true
        service.onEvent = { [weak self] event in self?.receive(event) }
        service.start()
    }

    private func receive(_ event: AuthSessionEvent) {
        guard acceptingSessionEvents else { return }
        let next: AuthUserInfo?
        switch event {
        case .changed(let value): next = value
        case .passwordRecovery(let value):
            recoveringPassword = true; next = value
        }
        if let expected = expectedLinkIdentity, let next = next, next.identity != expected {
            user = nil; generation = UUID(); onSessionChange?()
            message = "That sign-in method belongs to another account. Gardens were not merged. Sign in again."
            return
        }
        let changed = user?.identity != next?.identity
        user = next
        if changed { generation = UUID(); onSessionChange?() }
        if recoveringPassword { onSessionChange?() }
    }

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
        catch is CancellationError { message = "Sign-in cancelled. Your saved garden is unchanged." }
        catch { message = error.localizedDescription }
    }

    func signIn(email: String, password: String) async {
        await perform {
            self.acceptingSessionEvents = true
            try await self.service.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
    }
    func signUp(email: String, password: String) async {
        await perform {
            self.acceptingSessionEvents = true
            let signedIn = try await self.service.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            self.message = signedIn ? "Signed in. Continue to your game account." : "Check your email to confirm your account, then return here and sign in."
        }
    }
    func resetPassword(email: String) async {
        await perform({ try await self.service.resetPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) },
                      success: "If this address has an account, a password-reset email will arrive shortly. Open it on this iPhone.")
    }
    func resendConfirmation(email: String) async {
        await perform({ try await self.service.resendConfirmation(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) },
                      success: "If confirmation is needed, check your email and open the link on this iPhone.")
    }
    func updatePassword(_ password: String) async {
        await perform {
            try await self.service.updatePassword(password)
            let wasRecovering = self.recoveringPassword
            self.recoveringPassword = false
            self.message = "Password saved. You can use email and password to sign in."
            if wasRecovering { self.onSessionChange?() }
        }
    }
    func updateEmail(_ email: String) async {
        await perform({ try await self.service.updateEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) },
                      success: "Follow the verification emails to confirm the email change. Your game account stays the same.")
    }
    func google(link: Bool) async {
        guard configuration.googleEnabled, !link || user != nil else { return }
        await perform {
            if !link { self.acceptingSessionEvents = true }
            self.expectedLinkIdentity = link ? self.user?.identity : nil
            try await self.service.google(link: link)
            if link, self.user?.identity != self.expectedLinkIdentity { throw Self.signInRequired }
            self.message = link ? "Google linked to this account." : "Signed in with Google."
        }
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

    func handleCallback(_ url: URL) async {
        guard configuration.accepts(url), !busy else { return }
        start()
        acceptingSessionEvents = true
        busy = true; message = nil
        defer { busy = false }
        let previousRecovery = recoveringPassword
        // Suspend game access before the SDK emits SIGNED_IN for recovery.
        if url.path == configuration.recoveryURL.path {
            recoveringPassword = true; onSessionChange?()
        }
        do {
            try await service.handleCallback(url)
            message = recoveringPassword ? "Choose your new password." : "Email confirmed. Continue to your garden."
        } catch {
            recoveringPassword = previousRecovery
            onSessionChange?()
            message = "This sign-in link could not be confirmed. Request a fresh email and open the newest link on this iPhone."
        }
    }

    func signOut() async {
        guard !busy else { return }
        busy = true; acceptingSessionEvents = false; generation = UUID(); user = nil; recoveringPassword = false
        onSessionChange?() // Revoke game access immediately, including offline/in-flight work.
        defer { busy = false }
        do { try await service.signOut(); message = "Signed out. Saved requests stay with their original account." }
        catch { message = "Signed out on this iPhone. The server could not confirm session revocation." }
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
