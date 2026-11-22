#if DEBUG
import Foundation

/// Explicit, isolated UI fixtures. No real auth, game request or player storage.
@MainActor
enum AuthEntryFixture {
    static func authentication() -> AuthenticationStore? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--fixture-auth") else { return nil }
        let config = try! AuthConfiguration.parse([
            "SupabaseURL": "https://fixture.supabase.invalid", "PublishableKey": "sb_publishable_fixture",
            "GameAPIURL": "https://fixture.game.invalid", "CallbackScheme": "com.test.auth",
            "GoogleEnabled": "YES", "AppleEnabled": "NO", "GuestEnabled": "YES"
        ])!
        let defaults = UserDefaults(suiteName: "forest-auth-fixture")!
        defaults.removePersistentDomain(forName: "forest-auth-fixture")
        let service = AuthEntryFixtureService()
        service.waits = arguments.contains("--auth-restoring")
        service.unavailable = arguments.contains("--auth-unavailable")
        if arguments.contains("--auth-signed-out") {
            defaults.set(true, forKey: "auth.entry.v1.fixture.supabase.invalid")
        }
        if arguments.contains("--auth-guest") || arguments.contains("--auth-linked") || arguments.contains("--auth-google-only") || arguments.contains("--auth-email-only") {
            let guest = arguments.contains("--auth-guest")
            let googleOnly = arguments.contains("--auth-google-only")
            let emailOnly = arguments.contains("--auth-email-only")
            service.cachedUser = AuthUserInfo(identity: AuthIdentity(issuer: config.issuer,
                subject: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
                email: guest ? nil : "player@example.invalid", methods: guest ? [] : googleOnly ? ["google"] : emailOnly ? ["email"] : ["email", "google"],
                isAnonymous: guest, emailVerified: !guest, hasEmailPassword: !guest && !googleOnly)
        }
        return AuthenticationStore(configuration: config, service: service, defaults: defaults)
    }
}

@MainActor
private final class AuthEntryFixtureService: AuthenticationServing {
    var cachedUser: AuthUserInfo?
    var onEvent: ((AuthSessionEvent) -> Void)?
    var waits = false
    var unavailable = false
    var pendingEmail: String?
    func start() {
        guard !waits else { return }
        onEvent?(unavailable ? .restoreFailed : .changed(cachedUser))
    }
    func accessToken(refresh: Bool) async throws -> AuthAccessToken { throw CancellationError() }
    func signIn(email: String, password: String) async throws { throw CancellationError() }
    func signUp(email: String, password: String) async throws -> Bool { throw CancellationError() }
    func resetPassword(email: String) async throws { throw CancellationError() }
    func resendConfirmation(email: String) async throws { throw CancellationError() }
    func updatePassword(_ password: String) async throws {
        guard cachedUser?.emailVerified == true else { throw CancellationError() }
        cachedUser?.hasEmailPassword = true; onEvent?(.changed(cachedUser))
    }
    func updateEmail(_ email: String) async throws { pendingEmail = email }
    func refreshUser() async throws -> AuthUserInfo {
        guard let user = cachedUser else { throw CancellationError() }; return user
    }
    func verifyEmailChange(email: String, code: String) async throws -> AuthUserInfo {
        guard code == "123456", email == pendingEmail, var user = cachedUser else { throw CancellationError() }
        user = AuthUserInfo(identity: user.identity, email: email, methods: Array(Set(user.methods + ["email"])).sorted(), emailVerified: true)
        cachedUser = user; return user
    }
    func google(link: Bool) async throws {
        guard link, var user = cachedUser else { throw CancellationError() }
        user = AuthUserInfo(identity: user.identity, email: user.email ?? "player@example.invalid",
            methods: Array(Set(user.methods + ["google"])).sorted(), emailVerified: true, hasEmailPassword: user.hasEmailPassword)
        cachedUser = user; onEvent?(.changed(user))
    }
    func apple(idToken: String, nonce: String, link: Bool) async throws { throw CancellationError() }
    func handleCallback(_ url: URL) async throws { throw CancellationError() }
    func signOut() async throws { cachedUser = nil; onEvent?(.changed(nil)) }
    func stagingService() throws -> any AuthenticationServing { AuthEntryFixtureService() }
}
#endif
