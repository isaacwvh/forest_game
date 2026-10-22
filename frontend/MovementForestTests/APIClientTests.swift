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
