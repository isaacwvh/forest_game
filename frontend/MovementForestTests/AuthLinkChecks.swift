import Foundation
#if canImport(MovementForest)
@testable import MovementForest
#endif

/// Shared by native XCTest and the portable Swift runner. The actual store,
/// identity scoping and persistence execute unchanged; only the auth server is fake.
@MainActor
enum AuthLinkChecks {
    private struct Failure: Error { let message: String }
    private final class Service: AuthenticationServing {
        var cachedUser: AuthUserInfo?
        var onEvent: ((AuthSessionEvent) -> Void)?
        var refreshed: AuthUserInfo?
        var verified: AuthUserInfo?
        var failure: Error?
        var emailCalls = 0
        var passwordCalls = 0
        var verifyCalls = 0
        var stage: Service?
        func start() { onEvent?(.changed(cachedUser)) }
        func accessToken(refresh: Bool) async throws -> AuthAccessToken {
            guard let user = cachedUser else { throw AuthenticationStore.signInRequired }
            return AuthAccessToken(identity: user.identity, value: "fixture-token")
        }
        func signIn(email: String, password: String) async throws { }
        func signUp(email: String, password: String) async throws -> Bool { false }
        func resetPassword(email: String) async throws { }
        func resendConfirmation(email: String) async throws { }
        func updateEmail(_ email: String) async throws {
            emailCalls += 1
            if let failure = failure { throw failure }
        }
        func updatePassword(_ password: String) async throws {
            passwordCalls += 1
            if let failure = failure { throw failure }
            cachedUser?.hasEmailPassword = true
            onEvent?(.changed(cachedUser))
        }
        func google(link: Bool) async throws { }
        func apple(idToken: String, nonce: String, link: Bool) async throws { }
        func handleCallback(_ url: URL) async throws {
            guard let user = cachedUser else { throw AuthenticationStore.signInRequired }
            onEvent?(.passwordRecovery(user))
        }
        func stagingService() throws -> any AuthenticationServing {
            let value = Service(); stage = value; return value
        }
        func signOut() async throws { cachedUser = nil; onEvent?(.changed(nil)) }
        func refreshUser() async throws -> AuthUserInfo {
            if let failure = failure { throw failure }
            guard let value = refreshed ?? cachedUser else { throw AuthenticationStore.signInRequired }
            return value
        }
        func verifyEmailChange(email: String, code: String) async throws -> AuthUserInfo {
            verifyCalls += 1
            if let failure = failure { throw failure }
            guard code == "123456", let value = verified else { throw AuthenticationStore.signInRequired }
            // A foreign response is returned without adopting it, as the adapter must do.
            if value.identity == cachedUser?.identity { cachedUser = value }
            return value
        }
    }

    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }; count += 1
        }
        var presentation = AuthEntryPresentationState()
        try check(!presentation.hasSignIn, "Cold callback requires an auth presentation")
        presentation.signInChanged(true)
        try check(presentation.hasSignIn, "Live sign-in owns recovery presentation")
        presentation.signInChanged(true); presentation.signInChanged(false)
        try check(presentation.hasSignIn, "Nested presentation cannot cancel an active sign-in")
        presentation.signInChanged(false); presentation.signInChanged(false)
        try check(!presentation.hasSignIn, "Dismissal clears presentation without underflow")
        let config = AuthConfiguration(projectURL: URL(string: "https://fixture.supabase.invalid")!,
            publishableKey: "sb_publishable_fixture", apiURL: URL(string: "https://fixture.game.invalid")!,
            callbackURL: URL(string: "com.test.auth://auth/callback")!, recoveryURL: URL(string: "com.test.auth://auth/reset-password")!,
            googleEnabled: true, appleEnabled: false, guestEnabled: true)
        let defaults = UserDefaults(suiteName: "auth-link-checks-" + UUID().uuidString)!
        let identity = AuthIdentity(issuer: config.issuer, subject: UUID())
        let service = Service()
        service.cachedUser = AuthUserInfo(identity: identity, email: nil, methods: [], isAnonymous: true)
        let auth = AuthenticationStore(configuration: config, service: service, defaults: defaults)
        auth.start()
        let tokens = try auth.scopedTokens()
        try check(auth.needsGuestExitWarning, "Unlinked guest needs departure warning")
        await auth.linkEmail("  rowan@gmail.com  ")
        try check(auth.emailLinkAddress == "rowan@gmail.com", "Trimmed email intent")
        try check(service.emailCalls == 1, "Update current account, never sign up")
        try check(auth.user?.identity == identity && auth.user?.isAnonymous == true, "Guest preserved while pending")
        try check(!auth.emailLinkVerified, "Pending is not verified")
        try check(auth.user?.hasEmailPassword == false, "No password claim before setup")
        let premature = await auth.updatePassword("example-password")
        try check(!premature && service.passwordCalls == 0, "Verification precedes password mutation")
        try tokens.validate()
        try check(auth.entryAction == .continueGarden, "Email setup never signs out guest")

        let reopened = AuthenticationStore(configuration: config, service: service, defaults: defaults)
        reopened.start()
        try check(reopened.emailLinkAddress == "rowan@gmail.com", "Intent survives process restart")
        try check(reopened.user?.identity == identity, "Same guest after restart")
        service.verified = AuthUserInfo(identity: identity, email: "rowan@gmail.com", methods: ["email"], emailVerified: true)
        await reopened.verifyLinkedEmail(code: "wrong")
        try check(!reopened.emailLinkVerified && reopened.user?.identity == identity, "Invalid code preserves guest")
        await reopened.verifyLinkedEmail(code: "123456")
        try check(reopened.emailLinkVerified, "Same-account email verified")
        try check(reopened.needsGuestExitWarning, "Password still pending after verification")
        try check(reopened.user?.hasEmailPassword == false, "Email identity alone is not password readiness")
        service.failure = URLError(.notConnectedToInternet)
        let failedPassword = await reopened.updatePassword("example-password")
        try check(!failedPassword && reopened.emailLinkAddress != nil, "Failed password retains resumable intent")
        service.failure = nil
        let saved = await reopened.updatePassword("example-password")
        try check(saved && reopened.user?.hasEmailPassword == true, "Confirmed password exposes settings")
        try check(reopened.emailLinkAddress == nil, "Completion clears pending intent")
        try check(!reopened.needsGuestExitWarning, "Completed email access is recoverable")
        try check(reopened.user?.identity == identity, "Upgrade preserves exact identity")
        try reopened.scopedTokens().validate()

        // Same Gmail can gain email/password while retaining Google.
        let google = Service()
        google.cachedUser = AuthUserInfo(identity: identity, email: "rowan@gmail.com", methods: ["google"], emailVerified: true)
        let googleAuth = AuthenticationStore(configuration: config, service: google,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        googleAuth.start()
        try check(googleAuth.user?.hasEmailPassword == false, "Google email never implies password")
        await googleAuth.linkEmail("rowan@gmail.com")
        try check(google.emailCalls == 0 && googleAuth.emailLinkVerified, "Verified Google email needs no redundant email change")
        let googlePassword = await googleAuth.updatePassword("example-password")
        try check(googlePassword && googleAuth.user?.methods.contains("google") == true, "Adding password keeps Google")
        try check(googleAuth.user?.identity == identity, "Same Gmail, same account")

        // A verified response for another user must never become a garden switch.
        let foreign = Service()
        foreign.cachedUser = AuthUserInfo(identity: identity, email: nil, methods: [], isAnonymous: true)
        let foreignAuth = AuthenticationStore(configuration: config, service: foreign,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        foreignAuth.start(); await foreignAuth.linkEmail("rowan@gmail.com")
        foreign.verified = AuthUserInfo(identity: AuthIdentity(issuer: config.issuer, subject: UUID()),
            email: "rowan@gmail.com", methods: ["email"], emailVerified: true)
        await foreignAuth.verifyLinkedEmail(code: "123456")
        try check(foreignAuth.user?.identity == identity, "Foreign verification rejected without losing guest")
        try check(!foreignAuth.emailLinkVerified, "Foreign response never marks linked")
        foreign.refreshed = foreign.verified
        await foreignAuth.refreshLinkedEmail()
        try check(foreignAuth.user?.identity == identity, "Foreign refresh rejected")
        foreign.failure = URLError(.notConnectedToInternet)
        await foreignAuth.linkEmail("other@gmail.com")
        try check(foreignAuth.user?.identity == identity, "Delivery/network failure preserves active guest")
        try check(foreignAuth.emailLinkAddress == "other@gmail.com", "Uncertain delivery remains resumable")

        // Password recovery remains isolated until the explicit garden handoff.
        let active = Service(); active.cachedUser = AuthUserInfo(identity: identity, email: nil, methods: [], isAnonymous: true)
        let activeAuth = AuthenticationStore(configuration: config, service: active,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        activeAuth.start()
        let activeTokens = try activeAuth.scopedTokens()
        let target = try activeAuth.prepareCandidate()
        let targetIdentity = AuthIdentity(issuer: config.issuer, subject: UUID())
        active.stage?.cachedUser = AuthUserInfo(identity: targetIdentity, email: "other@gmail.com", methods: ["email"], emailVerified: true)
        let callback = await target.handleCallback(config.recoveryURL)
        try check(callback && target.recoveringPassword, "Recovery belongs to staged account")
        try check(target.message == nil, "Recovery heading needs no lingering sign-in confirmation")
        try check(activeAuth.user?.identity == identity, "Current guest remains active")
        try activeTokens.validate()
        let reuseMessage = "Choose a different password from your current password."
        active.stage?.failure = ForestError.invalidData(reuseMessage)
        let rejected = await target.updatePassword("same-password")
        try check(!rejected && target.recoveringPassword, "Rejected password keeps recovery open for retry")
        try check(target.message == reuseMessage, "Password rejection retains its specific error")
        target.clearMessage()
        try check(target.message == nil && target.recoveringPassword, "Leaving a form clears feedback without changing recovery")
        active.stage?.failure = nil
        let recovered = await target.updatePassword("recovered-password")
        try check(recovered && !target.recoveringPassword, "Destination password reset finishes separately")
        try check(activeAuth.user?.identity == identity, "Reset never adopts destination implicitly")
        let restored = AuthenticationStore(configuration: config, service: active, defaults: defaults)
        restored.start()
        try check(restored.user?.identity == identity && restored.entryAction == .continueGarden, "Restored guest continues")
        try activeTokens.validate()
        try check(restored.user?.hasEmailPassword == false, "No leaked password capability from a different store")
        await restored.google(link: true)
        try check(restored.message == nil, "Google success needs no lingering confirmation")
        restored.report("Old form feedback")
        await restored.signOut()
        try check(restored.message == nil && restored.user == nil, "Sign-out clears old feedback without another notice")
        return count
    }
}
