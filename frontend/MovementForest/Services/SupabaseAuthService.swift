import Foundation
import Auth
import AuthenticationServices
import UIKit

/// Only this adapter depends on the SDK. Credentials/sessions remain in its
/// Keychain store; game queues contain no access or refresh tokens.
@MainActor
final class SupabaseAuthService: AuthenticationServing {
    private let client: AuthClient
    private let configuration: AuthConfiguration
    private let browser = AuthBrowser()
    private var observer: Task<Void, Never>?
    var onEvent: ((AuthSessionEvent) -> Void)?

    init(configuration: AuthConfiguration) {
        self.configuration = configuration
        client = AuthClient(configuration: .init(
            url: configuration.projectURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": configuration.publishableKey], flowType: .pkce,
            redirectToURL: configuration.callbackURL,
            storageKey: "movement-forest-\(configuration.projectURL.host ?? "auth")",
            localStorage: KeychainLocalStorage(service: "\(Bundle.main.bundleIdentifier ?? "MovementForest").SupabaseAuth"),
            emitLocalSessionAsInitialSession: true))
    }
    deinit { observer?.cancel() }

    var cachedUser: AuthUserInfo? { client.currentSession.map { info($0.user) } }
    private func info(_ user: Auth.User) -> AuthUserInfo {
        AuthUserInfo(identity: AuthIdentity(issuer: configuration.issuer, subject: user.id), email: user.email,
                     methods: Array(Set((user.identities ?? []).map(\.provider))).sorted())
    }
    func start() {
        guard observer == nil else { return }
        observer = Task { [weak self, client] in
            for await (event, session) in client.authStateChanges {
                guard !Task.isCancelled, let self = self else { return }
                if event == .passwordRecovery, let session = session {
                    self.onEvent?(.passwordRecovery(self.info(session.user)))
                } else { self.onEvent?(.changed(self.cachedUser)) }
            }
        }
    }

    func accessToken(refresh: Bool) async throws -> AuthAccessToken {
        do {
            let session: Session
            if refresh { session = try await client.refreshSession() }
            else { session = try await client.session }
            return AuthAccessToken(identity: info(session.user).identity, value: session.accessToken)
        } catch let error as AuthError {
            let terminal = ["session_not_found", "refresh_token_not_found", "refresh_token_already_used", "user_banned", "user_not_found"]
            if terminal.contains(error.errorCode.rawValue) {
                onEvent?(.changed(nil)); throw AuthenticationStore.signInRequired
            }
            throw publicError(error)
        }
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
        do {
            let previous = cachedUser?.identity
            let session: Session
            if link {
                let result = try await client.getLinkIdentityURL(provider: .google, redirectTo: configuration.callbackURL)
                let url = try await browser.open(result.url, callback: configuration.callbackURL)
                session = try await client.session(from: url)
                guard info(session.user).identity == previous else {
                    try? await client.signOut(scope: .local)
                    throw AuthenticationStore.signInRequired
                }
            } else {
                session = try await client.signInWithOAuth(provider: .google, redirectTo: configuration.callbackURL,
                    launchFlow: { [browser, configuration] url in try await browser.open(url, callback: configuration.callbackURL) })
            }
            onEvent?(.changed(info(session.user)))
        } catch { throw publicError(error) }
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
        do { let session = try await client.session(from: url); onEvent?(.changed(info(session.user))) }
        catch { throw publicError(error) }
    }
    func signOut() async throws { try await client.signOut(scope: .local) }

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
            case "identity_already_exists", "email_exists": message = "This sign-in method already belongs to an account. Sign in to that account; gardens cannot be merged."
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

@MainActor
private final class AuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    var active: Bool { session != nil }
    func open(_ url: URL, callback: URL) async throws -> URL {
        guard session == nil else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: callback.scheme) { [weak self] result, error in
                Task { @MainActor in
                    self?.session = nil
                    if let error = error { continuation.resume(throwing: error) }
                    else if let result = result, result.scheme == callback.scheme,
                            result.host == callback.host, result.path == callback.path {
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
