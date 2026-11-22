"""Prepare shared auth checks for portable Swift; no Apple SDK coverage implied.

Only Combine observation and CryptoKit's SHA-256 interface are substituted. The
SHA-256 shim calls the system sha256sum; actual store/config/checks are retained.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".validation-tools/auth"
OUT.mkdir(parents=True, exist_ok=True)
api = (ROOT / "MovementForest/Services/APIClient.swift").read_text(encoding="utf-8")
garden = (ROOT / "MovementForest/Models/GardenModels.swift").read_text(encoding="utf-8")
interfaces = '''import Foundation
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.standardInput = input; process.standardOutput = output
        try! process.run()
        input.fileHandleForWriting.write(data); try! input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let hex = String(decoding: bytes, as: UTF8.self).prefix(64)
        return stride(from: 0, to: 64, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
'''
interfaces += api[api.index("struct APIError:"):api.index("private struct APIErrorEnvelope")]
interfaces += api[api.index("@MainActor\nprotocol TokenProviding"):api.index("struct FixedTokenProvider")]
interfaces += garden[garden.index("enum ForestError:"):garden.index("/// Board-local")]
interfaces += "enum APIClient {\n" + api[api.index("    static func validatedURL"):api.index("    @MainActor\n    func request")] + "}\n"
store = (ROOT / "MovementForest/Services/AuthenticationStore.swift").read_text(encoding="utf-8")
store = store.replace("import Combine\n", "").replace("import CryptoKit\n", "")
config = (ROOT / "MovementForest/Services/AuthConfiguration.swift").read_text(encoding="utf-8")
checks = (ROOT / "MovementForestTests/AuthLinkChecks.swift").read_text(encoding="utf-8")
main = '''
let count = try await AuthLinkChecks.run()
precondition(count == 38)
print("PASS: \\(count) shared auth identity, verification, persistence and recovery checks.")
'''
(OUT / "AuthChecks.swift").write_text(interfaces + config + store + checks + main, encoding="utf-8")
print(OUT / "AuthChecks.swift")
