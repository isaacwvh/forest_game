import Foundation

struct AuthConfiguration {
    let projectURL: URL
    let publishableKey: String
    let apiURL: URL
    let callbackURL: URL
    let recoveryURL: URL
    let googleEnabled: Bool
    let appleEnabled: Bool
    var issuer: String { projectURL.appendingPathComponent("auth/v1").absoluteString }

    static func load(bundle: Bundle = .main) throws -> AuthConfiguration? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FOREST_DISABLE_AUTH"] == "1" ||
            ProcessInfo.processInfo.arguments.contains("--fixture-health") { return nil }
        #endif
        return try parse(bundle.object(forInfoDictionaryKey: "ForestAuth") as? [String: String] ?? [:])
    }

    static func parse(_ values: [String: String]) throws -> AuthConfiguration? {
        func value(_ key: String) -> String {
            let text = (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasPrefix("$(") ? "" : text
        }
        let project = value("SupabaseURL"), key = value("PublishableKey"), api = value("GameAPIURL")
        if project.isEmpty && key.isEmpty && api.isEmpty { return nil }
        guard !project.isEmpty, key.hasPrefix("sb_publishable_"), !api.isEmpty else {
            throw ForestError.invalidData("Complete Supabase URL, publishable key and HTTPS game API URL in Configuration/Local.xcconfig. Use a publishable key, never a secret/service-role key.")
        }
        let projectURL = try APIClient.validatedURL(project)
        let apiURL = try APIClient.validatedURL(api)
        let scheme = value("CallbackScheme")
        guard !scheme.isEmpty, scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil,
              !["http", "https"].contains(scheme.lowercased()),
              let callback = URL(string: "\(scheme)://auth/callback"),
              let recovery = URL(string: "\(scheme)://auth/reset-password") else {
            throw ForestError.invalidData("Configure a unique app callback URL scheme.")
        }
        return AuthConfiguration(projectURL: projectURL, publishableKey: key, apiURL: apiURL,
                                 callbackURL: callback, recoveryURL: recovery,
                                 googleEnabled: value("GoogleEnabled") == "YES", appleEnabled: value("AppleEnabled") == "YES")
    }

    func accepts(_ url: URL) -> Bool {
        [callbackURL, recoveryURL].contains { expected in
            url.scheme == expected.scheme && url.host == expected.host && url.path == expected.path &&
                url.user == nil && url.password == nil && url.port == nil
        }
    }
}
