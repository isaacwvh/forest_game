import XCTest
import Foundation
@testable import MovementForest

@MainActor
private final class FakeAuthentication: AuthenticationServing {
    var cachedUser: AuthUserInfo?
    var onEvent: ((AuthSessionEvent) -> Void)?
    var value = "access-one"
    var refreshCount = 0
    var tokenCount = 0
    var failure: Error?
    var onToken: (() -> Void)?
    var confirmedSignup = false
    var linkedIdentity: AuthIdentity?
    var calls: [String] = []
    func emit(_ user: AuthUserInfo?) { cachedUser = user; onEvent?(.changed(user)) }
    func start() { onEvent?(.changed(cachedUser)) }
    func accessToken(refresh: Bool) async throws -> AuthAccessToken {
        tokenCount += 1
        if let failure = failure { throw failure }
        guard let user = cachedUser else { throw AuthenticationStore.signInRequired }
        if refresh { refreshCount += 1; value = "access-refreshed" }
        onToken?()
        return AuthAccessToken(identity: user.identity, value: value)
    }
    func signIn(email: String, password: String) async throws { calls.append("signin") }
    func signUp(email: String, password: String) async throws -> Bool { calls.append("signup"); return confirmedSignup }
    func resetPassword(email: String) async throws { calls.append("reset") }
    func resendConfirmation(email: String) async throws { calls.append("resend") }
    func updatePassword(_ password: String) async throws { calls.append("password") }
    func updateEmail(_ email: String) async throws { calls.append("email") }
    func google(link: Bool) async throws {
        calls.append(link ? "link-google" : "signin-google")
        if let identity = linkedIdentity { emit(AuthUserInfo(identity: identity, email: "relay@test.invalid", methods: ["apple", "google"])) }
    }
    func apple(idToken: String, nonce: String, link: Bool) async throws { calls.append(link ? "link-apple" : "signin-apple") }
    func handleCallback(_ url: URL) async throws { calls.append("callback") }
    func signOut() async throws { emit(nil) }
}

@MainActor
private final class AuthHTTPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var statuses: [Int]
    var beforeResponse: (() -> Void)?
    init(_ statuses: [Int] = [200]) { self.statuses = statuses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        beforeResponse?()
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        let data = status == 200 ? Data("{\"status\":\"ok\"}".utf8) :
            Data("{\"error\":{\"code\":\"invalid_token\",\"message\":\"Expired\"}}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class AuthenticationTests: XCTestCase {
    private func configuration() throws -> AuthConfiguration {
        try XCTUnwrap(AuthConfiguration.parse([
            "SupabaseURL": "https://project.supabase.co", "PublishableKey": "sb_publishable_test",
            "GameAPIURL": "https://game.test", "CallbackScheme": "com.test.forest",
            "GoogleEnabled": "YES", "AppleEnabled": "YES"
        ]))
    }
    private func user(_ id: UUID = UUID()) -> AuthUserInfo {
        AuthUserInfo(identity: AuthIdentity(issuer: "https://project.supabase.co/auth/v1", subject: id),
                     email: "person@test.invalid", methods: ["email"])
    }
    private func store(_ service: FakeAuthentication) throws -> AuthenticationStore {
        let store = AuthenticationStore(configuration: try configuration(), service: service)
        store.start(); return store
    }

    func testPartialOrSecretConfigurationFailsClosed() throws {
        XCTAssertNil(try AuthConfiguration.parse([:]))
        for key in ["", "sb_secret_bad", "eyJ_service_role_or_legacy_key"] {
            XCTAssertThrowsError(try AuthConfiguration.parse([
                "SupabaseURL": "https://project.supabase.co", "PublishableKey": key,
                "GameAPIURL": "https://game.test", "CallbackScheme": "com.test.forest"
            ]))
        }
    }
    func testCallbackChecksHostPathSchemeAndRejectsCredentials() throws {
        let config = try configuration()
        XCTAssertTrue(config.accepts(URL(string: "com.test.forest://auth/callback?code=one")!))
        XCTAssertTrue(config.accepts(config.recoveryURL))
        for url in ["other://auth/callback", "com.test.forest://evil/callback", "com.test.forest://auth/wrong",
                    "com.test.forest://user:pass@auth/callback", "com.test.forest://auth:42/callback"] {
            XCTAssertFalse(config.accepts(URL(string: url)!))
        }
    }
    func testConfirmationPendingDoesNotEstablishGameIdentity() async throws {
        let service = FakeAuthentication(), auth = try store(service)
        await auth.signUp(email: "test@test.invalid", password: "example-password")
        XCTAssertNil(auth.user)
        XCTAssertThrowsError(try auth.scopedTokens())
        XCTAssertTrue(auth.message?.contains("Check your email") == true)
    }
    func testRefreshRetriesExactlyTheSameMutationOnlyOnce() async throws {
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = try store(service), transport = AuthHTTPTransport([401, 200])
        let client = APIClient(baseURL: try configuration().apiURL, tokens: try auth.scopedTokens(), transport: transport)
        let body = Data("{\"requestId\":\"unchanged\",\"steps\":1234}".utf8)
        let _: [String: String] = try await client.request("v1/activity/sync", method: "POST", body: body)
        XCTAssertEqual(service.refreshCount, 1)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].httpBody, transport.requests[1].httpBody)
        XCTAssertEqual(transport.requests[0].url, transport.requests[1].url)
        XCTAssertEqual(transport.requests[0].httpMethod, transport.requests[1].httpMethod)
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-refreshed")
    }
    func testRepeated401DoesNotLoop() async throws {
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = try store(service), transport = AuthHTTPTransport([401])
        let client = APIClient(baseURL: try configuration().apiURL, tokens: try auth.scopedTokens(), transport: transport)
        do { let _: [String: String] = try await client.request("v1/me"); XCTFail("Expected 401") }
        catch let error as APIError { XCTAssertEqual(error.status, 401) }
        XCTAssertEqual(transport.requests.count, 2); XCTAssertEqual(service.refreshCount, 1)
    }
    func testAccountChangesWhileGettingTokenPreventTransmission() async throws {
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = try store(service), transport = AuthHTTPTransport()
        let client = APIClient(baseURL: try configuration().apiURL, tokens: try auth.scopedTokens(), transport: transport)
        service.onToken = { service.emit(nil) }
        do { let _: [String: String] = try await client.request("v1/activity/sync"); XCTFail("Expected identity rejection") }
        catch let error as APIError { XCTAssertEqual(error.status, 401) }
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testOldAccountResponseIsRejectedAfterSwitching() async throws {
        let service = FakeAuthentication(); let first = user(); service.cachedUser = first
        let auth = try store(service), transport = AuthHTTPTransport()
        let client = APIClient(baseURL: try configuration().apiURL, tokens: try auth.scopedTokens(), transport: transport)
        let second = user()
        transport.beforeResponse = { service.emit(second) }
        do { let _: [String: String] = try await client.request("v1/me/garden"); XCTFail("Expected identity rejection") }
        catch let error as APIError { XCTAssertEqual(error.status, 401) }
        XCTAssertEqual(auth.user?.identity, second.identity)
        XCTAssertEqual(transport.requests.count, 1)
    }
    func testOfflineRefreshDoesNotInventNewIdentity() async throws {
        let service = FakeAuthentication(); let first = user(); service.cachedUser = first
        let auth = try store(service)
        service.failure = URLError(.notConnectedToInternet)
        do { _ = try await auth.scopedTokens().token(); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(auth.user?.identity, first.identity)
    }
    func testExplicitLogoutInvalidatesOldTokensEvenAfterSameAccountLogin() async throws {
        let service = FakeAuthentication(); let first = user(); service.cachedUser = first
        let auth = try store(service), tokens = try auth.scopedTokens()
        await auth.signOut()
        service.emit(first) // An already queued SDK event must not undo logout.
        XCTAssertNil(auth.user)
        await auth.signIn(email: "person@test.invalid", password: "example-password")
        service.emit(first)
        XCTAssertThrowsError(try tokens.validate())
        let value = try await auth.scopedTokens().token()
        XCTAssertEqual(value, "access-one")
    }
    func testLinkingDifferentEmailKeepsTokenScopeAndGameIdentity() async throws {
        let service = FakeAuthentication(); let first = user(); service.cachedUser = first
        let auth = try store(service), tokens = try auth.scopedTokens()
        service.linkedIdentity = first.identity
        await auth.google(link: true)
        XCTAssertEqual(auth.user?.identity, first.identity)
        XCTAssertEqual(auth.user?.email, "relay@test.invalid")
        XCTAssertNoThrow(try tokens.validate())
        XCTAssertEqual(service.calls, ["link-google"])
    }
    func testUnexpectedIdentityDuringLinkingCannotAcquireGameAccess() async throws {
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = try store(service), tokens = try auth.scopedTokens()
        service.linkedIdentity = user().identity
        await auth.google(link: true)
        XCTAssertNil(auth.user); XCTAssertThrowsError(try tokens.validate())
    }
    func testRecoverySuspendsGameTokensUntilPasswordSaved() async throws {
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = try store(service), tokens = try auth.scopedTokens()
        await auth.handleCallback(try configuration().recoveryURL)
        XCTAssertTrue(auth.recoveringPassword)
        XCTAssertThrowsError(try tokens.validate())
        await auth.updatePassword("new-example-password")
        XCTAssertFalse(auth.recoveringPassword)
        XCTAssertEqual(service.calls, ["callback", "password"])
    }
    func testDifferentSubjectsAndProjectsHaveDifferentRegistrationScopes() {
        let identity = user().identity
        XCTAssertNotEqual(identity.storageScope, user().identity.storageScope)
        XCTAssertNotEqual(identity.storageScope, AuthIdentity(issuer: "https://different.supabase.co/auth/v1", subject: identity.subject).storageScope)
    }
}
