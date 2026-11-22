import XCTest
import Foundation
import Auth
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
    var stage: FakeAuthentication?
    var anonymousCalls = 0
    var adoptionFailure = false
    var staleGuestCache = false
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
    func signInAnonymously() async throws -> AuthUserInfo {
        anonymousCalls += 1
        if let failure = failure { throw failure }
        let guest = AuthUserInfo(identity: AuthIdentity(issuer: "https://project.supabase.co/auth/v1", subject: UUID()),
                                 email: nil, methods: [], isAnonymous: true)
        emit(guest)
        if staleGuestCache { cachedUser = nil }
        return guest
    }
    func stagingService() throws -> any AuthenticationServing {
        if let stage = stage { return stage }
        let value = FakeAuthentication(); stage = value; return value
    }
    func adopt(_ candidate: any AuthenticationServing) async throws {
        if adoptionFailure { throw URLError(.cannotWriteToFile) }
        guard let next = candidate.cachedUser else { throw AuthenticationStore.signInRequired }
        emit(next)
    }
    func discard() async throws { emit(nil) }
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
    func testReusedPasswordHasSpecificMessage() throws {
        let response = HTTPURLResponse(url: try configuration().projectURL,
            statusCode: 422, httpVersion: nil, headerFields: nil)!
        let error = AuthError.api(message: "New password should be different from the old password.",
            errorCode: .samePassword, underlyingData: Data(), underlyingResponse: response)
        let service = SupabaseAuthService(configuration: try configuration())
        XCTAssertEqual(service.publicError(error).localizedDescription,
            "Choose a different password from your current password.")
    }
    func testSharedEmailLinkPersistenceAndIdentityChecks() async throws {
        let count = try await AuthLinkChecks.run()
        XCTAssertEqual(count, 44)
    }
    private func configuration() throws -> AuthConfiguration {
        try XCTUnwrap(AuthConfiguration.parse([
            "SupabaseURL": "https://project.supabase.co", "PublishableKey": "sb_publishable_test",
            "GameAPIURL": "https://game.test", "CallbackScheme": "com.test.forest",
            "GoogleEnabled": "YES", "AppleEnabled": "YES", "GuestEnabled": "YES"
        ]))
    }
    private func user(_ id: UUID = UUID()) -> AuthUserInfo {
        AuthUserInfo(identity: AuthIdentity(issuer: "https://project.supabase.co/auth/v1", subject: id),
                     email: "person@test.invalid", methods: ["email"])
    }
    private func store(_ service: FakeAuthentication) throws -> AuthenticationStore {
        let defaults = UserDefaults(suiteName: "auth-tests-" + UUID().uuidString)!
        let store = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
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

    func testFreshEntryWaitsForRestoreAndNeverCreatesGuestOnStart() throws {
        let service = FakeAuthentication()
        let auth = AuthenticationStore(configuration: try configuration(), service: service,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(auth.entryAction, .restoring)
        auth.start()
        XCTAssertEqual(auth.entryAction, .play)
        XCTAssertNil(service.stage)
        XCTAssertEqual(service.anonymousCalls, 0)
    }

    func testEmptyGuestKeychainIsNotAnUnavailableSession() throws {
        let storage = SessionKeychainStorage(service: "forest-auth-tests-" + UUID().uuidString)
        let key = "test-session"
        defer { try? storage.remove(key: key) }
        XCTAssertNil(try storage.retrieve(key: key))
        XCTAssertNoThrow(try storage.remove(key: key))
        let session = Data("test-session-bytes".utf8)
        try storage.store(key: key, value: session)
        XCTAssertEqual(try storage.retrieve(key: key), session)
        try storage.remove(key: key)
        XCTAssertNil(try storage.retrieve(key: key))
        XCTAssertNoThrow(try storage.remove(key: key))
    }

    func testGuestCreationIsStagedAndReusesPendingGuest() async throws {
        let service = FakeAuthentication(), auth = try store(service)
        let guestResult1 = await auth.createGuest()
        XCTAssertTrue(guestResult1)
        let guest = try XCTUnwrap(auth.candidate?.user)
        XCTAssertTrue(guest.isAnonymous)
        XCTAssertNil(auth.user)
        let guestResult2 = await auth.createGuest()
        XCTAssertTrue(guestResult2)
        XCTAssertEqual(auth.candidate?.user?.identity, guest.identity)
        XCTAssertEqual(service.stage?.anonymousCalls, 1)
        try await auth.commitCandidate()
        XCTAssertEqual(auth.user?.identity, guest.identity)
        XCTAssertEqual(auth.entryAction, .continueGarden)
    }

    func testGuestSignupResultSurvivesStaleSignedOutCache() async throws {
        let service = FakeAuthentication(), auth = try store(service)
        _ = try auth.prepareCandidate()
        service.stage?.staleGuestCache = true
        let created = await auth.createGuest()
        XCTAssertTrue(created)
        XCTAssertTrue(auth.candidate?.user?.isAnonymous == true)
        XCTAssertNil(auth.user)
        XCTAssertNil(auth.message)
        let tokens = try XCTUnwrap(auth.candidate).scopedTokens()
        XCTAssertNoThrow(try tokens.validate())
        XCTAssertEqual(service.stage?.anonymousCalls, 1)
    }

    func testFailedGuestCreationAndFailedAdoptionPreserveCurrentAccount() async throws {
        let service = FakeAuthentication(); let original = user(); service.cachedUser = original
        let auth = try store(service), tokens = try auth.scopedTokens()
        let staged = try auth.prepareCandidate()
        service.stage?.failure = URLError(.notConnectedToInternet)
        let guestResult3 = await auth.createGuest()
        XCTAssertFalse(guestResult3)
        XCTAssertEqual(auth.user, original)
        XCTAssertNoThrow(try tokens.validate())
        service.stage?.failure = nil
        let guestResult4 = await auth.createGuest()
        XCTAssertTrue(guestResult4)
        service.adoptionFailure = true
        do { try await auth.commitCandidate(); XCTFail("Expected storage failure") } catch { }
        XCTAssertEqual(auth.user, original)
        XCTAssertNotNil(staged.user)
        XCTAssertNoThrow(try tokens.validate())
    }

    func testCancellingStagedLoginPreservesGuestAndItsTokenScope() async throws {
        let service = FakeAuthentication()
        service.cachedUser = AuthUserInfo(identity: user().identity, email: nil, methods: [], isAnonymous: true)
        let auth = try store(service), tokens = try auth.scopedTokens()
        let original = auth.user
        let candidate = try auth.prepareCandidate()
        service.stage?.emit(user())
        XCTAssertNotEqual(candidate.user?.identity, original?.identity)
        XCTAssertEqual(auth.user, original)
        await auth.cancelCandidate()
        XCTAssertNil(auth.candidate)
        XCTAssertEqual(auth.user, original)
        XCTAssertNoThrow(try tokens.validate())
    }

    func testConfirmedSwitchRevokesOldScopeAndPreservesDestination() async throws {
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = try store(service), tokens = try auth.scopedTokens()
        _ = try auth.prepareCandidate()
        let target = user(); service.stage?.emit(target)
        try await auth.commitCandidate()
        XCTAssertEqual(auth.user, target)
        XCTAssertThrowsError(try tokens.validate())
        XCTAssertNil(auth.candidate)
    }

    func testLogoutPersistsAcrossLaunchAndStaleCachedSessionCannotRestore() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = FakeAuthentication(); let original = user(); service.cachedUser = original
        let auth = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
        auth.start(); await auth.signOut()
        service.cachedUser = original // Simulate an unavailable Keychain deletion.
        let reopened = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
        reopened.start()
        XCTAssertNil(reopened.user)
        XCTAssertEqual(reopened.entryAction, .signIn)
        XCTAssertTrue(reopened.hasHistory)
    }

    func testUnavailableRestoreCannotCreateGuest() async throws {
        let service = FakeAuthentication(), auth = try store(service)
        service.onEvent?(.restoreFailed)
        XCTAssertEqual(auth.entryAction, .retry)
        let guestResult5 = await auth.createGuest()
        XCTAssertFalse(guestResult5)
        XCTAssertNil(auth.candidate)
    }

    func testGuestRolloutDisabledStillRestoresExistingGuest() async throws {
        var config = try configuration(); config.guestEnabled = false
        let service = FakeAuthentication()
        service.cachedUser = AuthUserInfo(identity: user().identity, email: nil, methods: [], isAnonymous: true)
        let auth = AuthenticationStore(configuration: config, service: service,
                                       defaults: UserDefaults(suiteName: UUID().uuidString)!)
        auth.start()
        XCTAssertEqual(auth.entryAction, .continueGarden)
        let guestResult6 = await auth.createGuest()
        XCTAssertFalse(guestResult6)
    }

    func testBootstrapJournalRetainsExactBytesAcrossRetryAndPartitionsIdentities() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = AccountBootstrapJournal(disk: AccountDiskStore(directory: folder))
        let identity = user().identity
        let first = try journal.pending(server: "https://game.test", identity: identity, timezone: "Asia/Singapore")
        let retry = try journal.pending(server: "https://game.test", identity: identity, timezone: "Europe/London")
        XCTAssertEqual(first.requestId, retry.requestId)
        XCTAssertEqual(first.body, retry.body)
        let otherIdentity = user().identity
        let other = try journal.pending(server: "https://game.test", identity: otherIdentity, timezone: "UTC")
        XCTAssertNotEqual(first.requestId, other.requestId)
        try journal.clear(server: "https://game.test", identity: identity)
        let again = try journal.pending(server: "https://game.test", identity: identity, timezone: "UTC")
        XCTAssertNotEqual(first.requestId, again.requestId)
        XCTAssertEqual(try journal.pending(server: "https://game.test", identity: otherIdentity, timezone: "UTC").requestId, other.requestId)
    }

    func testLostGuestHintSurvivesCredentialLossAndClearsWhenLinked() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = FakeAuthentication()
        let identity = user().identity
        service.cachedUser = AuthUserInfo(identity: identity, email: nil, methods: [], isAnonymous: true)
        let auth = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
        auth.start()
        XCTAssertTrue(auth.lastWasGuest)
        service.emit(nil)
        let reopened = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
        reopened.start()
        XCTAssertEqual(reopened.entryAction, .signIn)
        XCTAssertTrue(reopened.lastWasGuest)
        service.emit(AuthUserInfo(identity: identity, email: "test@example.invalid", methods: ["google"]))
        XCTAssertFalse(reopened.lastWasGuest)
    }

    func testPasswordRecoveryRemainsGatedAcrossColdLaunch() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = FakeAuthentication(); service.cachedUser = user()
        let auth = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
        auth.start()
        await auth.handleCallback(try configuration().recoveryURL)
        let reopened = AuthenticationStore(configuration: try configuration(), service: service, defaults: defaults)
        reopened.start()
        XCTAssertTrue(reopened.recoveringPassword)
        XCTAssertThrowsError(try reopened.scopedTokens())
        await reopened.updatePassword("new-example-password")
        XCTAssertFalse(reopened.recoveringPassword)
        XCTAssertNoThrow(try reopened.scopedTokens())
    }
}
