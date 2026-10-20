import Foundation

struct APIError: Error, LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let error: Detail
}

protocol TokenProviding {
    func token() throws -> String
}

struct FixedTokenProvider: TokenProviding {
    let value: String
    func token() throws -> String { value }
}

protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

struct APIClient {
    let baseURL: URL
    let tokens: any TokenProviding
    let transport: any HTTPTransport

    init(baseURL: URL, tokens: any TokenProviding, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL; self.tokens = tokens; self.transport = transport
    }

    static func validatedURL(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host != nil, components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ForestError.invalidData("Enter the HTTPS address of your development API, without a path or credentials.")
        }
        components.path = ""
        components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
                               query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated { request.setValue("Bearer \(try tokens.token())", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let detail = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw APIError(status: response.statusCode, code: detail?.error.code ?? "http_error",
                           message: detail?.error.message ?? "The server could not complete this request (\(response.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor
protocol GardenServing {
    var serverID: String { get }
    func profile() async throws -> APIProfile
    func catalogue() async throws -> APICatalogue
    func garden() async throws -> APIGarden
    func inventory(after: UUID?) async throws -> APIInventory
    func edit(body: Data) async throws -> GardenEditResult
}

struct APIGardenRepository: GardenServing {
    let client: APIClient
    var serverID: String { client.baseURL.absoluteString }
    func profile() async throws -> APIProfile { try await client.request("v1/me") }
    func catalogue() async throws -> APICatalogue { try await client.request("v1/catalog") }
    func garden() async throws -> APIGarden { try await client.request("v1/me/garden") }
    func inventory(after: UUID?) async throws -> APIInventory {
        var query = [URLQueryItem(name: "limit", value: "30")]
        if let after = after { query.append(URLQueryItem(name: "after", value: after.uuidString)) }
        return try await client.request("v1/me/inventory", query: query)
    }
    func edit(body: Data) async throws -> GardenEditResult {
        try await client.request("v1/me/garden/edits", method: "POST", body: body)
    }
}
