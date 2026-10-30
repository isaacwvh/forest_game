import XCTest
import Foundation
@testable import MovementForest

private final class RecordingHTTPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let data: Data
    let status: Int
    init(_ data: Data, status: Int = 200) { self.data = data; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class APIClientTests: XCTestCase {
    func testCompactCompletionIsTypedAndAdvertisesRecovery() async throws {
        let id = UUID()
        let body = Data("{\"requestId\":\"\(id.uuidString)\"}".utf8)
        let payload = Data("""
        {"recovery":{"version":1,"status":"completed","requestId":"\(id.uuidString)",
        "operation":"visitor_claim","acceptedAt":"2026-10-30T12:00:00Z",
        "outcome":{"visits":"0","tokens":"0"},"refreshRequired":true}}
        """.utf8)
        let transport = RecordingHTTPTransport(payload)
        let client = APIClient(baseURL: try APIClient.validatedURL("https://garden.test"),
                               tokens: FixedTokenProvider(value: "test"), transport: transport)
        do {
            let _: APIVisitorReward = try await client.request("v1/me/stored-visits/claim", method: "POST", body: body)
            XCTFail("Expected typed completion")
        } catch let result as RequestRecovery {
            try result.validate(id: id, operation: "visitor_claim")
            XCTAssertEqual(result.outcome.visits, "0")
            XCTAssertThrowsError(try result.validate(id: UUID(), operation: "visitor_claim"))
            XCTAssertThrowsError(try result.validate(id: id, operation: "visitor_welcome"))
        }
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "X-Forest-Recovery"), "1")
        XCTAssertEqual(transport.requests.first?.httpBody, body)
    }

    func testStaleControlCannotBeAcceptedAsRewardCompletion() throws {
        let id = UUID()
        let value = RequestRecovery(version: 1, status: "stale_control", requestId: id,
            operation: "visitor_start", acceptedAt: nil,
            outcome: .init(gardenId: nil, controlSequence: 12, visits: nil, tokens: nil), refreshRequired: true)
        try value.validate(id: id, operation: "visitor_start", control: true)
        XCTAssertThrowsError(try value.validate(id: id, operation: "visitor_start"))
    }

    func testConnectionURLsAreCanonicalAndCannotContainCredentialsOrPaths() throws {
        XCTAssertEqual(try APIClient.validatedURL("https://GARDEN.test:443/").absoluteString, "https://garden.test")
        for address in ["http://garden.test", "https://user:secret@garden.test", "https://garden.test/v1", "https://garden.test?token=x"] {
            XCTAssertThrowsError(try APIClient.validatedURL(address))
        }
    }

    func testReadinessOmitsTokenAndAuthenticatedRequestUsesHeader() async throws {
        let transport = RecordingHTTPTransport(Data("{\"status\":\"ready\"}".utf8))
        let client = APIClient(baseURL: try APIClient.validatedURL("https://garden.test"),
                               tokens: FixedTokenProvider(value: "synthetic-test-token"), transport: transport)
        let _: [String: String] = try await client.request("health/ready", authenticated: false)
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Authorization"))
        let _: [String: String] = try await client.request("v1/me", query: [URLQueryItem(name: "after", value: "a b")])
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-token")
        XCTAssertEqual(transport.requests[1].url?.path, "/v1/me")
        XCTAssertFalse(transport.requests[1].url!.absoluteString.contains("synthetic-test-token"))
    }

    func testStructuredErrorsReachEditorWithoutEchoingPayload() async throws {
        let transport = RecordingHTTPTransport(Data("{\"error\":{\"code\":\"stale_catalogue\",\"message\":\"Refresh the catalogue\"}}".utf8), status: 409)
        let client = APIClient(baseURL: try APIClient.validatedURL("https://garden.test"),
                               tokens: FixedTokenProvider(value: "test"), transport: transport)
        do {
            let _: [String: String] = try await client.request("v1/me/garden/edits", method: "POST", body: Data("{}".utf8))
            XCTFail("Expected structured rejection")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "stale_catalogue")
            XCTAssertEqual(error.message, "Refresh the catalogue")
        }
    }
}
