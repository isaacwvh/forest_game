"""Prepare actual visitor logic/native tests for portable Swift XCTest.

Only Combine observation and CryptoKit's SHA-256 interface are substituted.
Rendering/SwiftUI/UIKit tests remain native-only; this is not an iOS build.
Run the emitted Swift package with VISITOR_FIXTURE pointing at visitor-contract.json.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".validation-tools/performance"
TESTS = OUT / "Tests/PerformanceTests"
TESTS.mkdir(parents=True, exist_ok=True)


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor] + "\n"


interfaces = '''import Foundation
import XCTest
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
struct DiagnosticHistory {
    static var shared: Self { Self() }
    static func scope(server: String, user: UUID) -> String { server + "|" + user.uuidString }
    func record(_ category: String, _ outcome: String, requestID: String? = nil, scope: String? = nil) {}
}
enum LifecycleDiagnostics { static func event(_ message: String) {} }
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
api = read("MovementForest/Services/APIClient.swift")
interfaces += block(api, "struct APIError:")
interfaces += block(api, "struct RequestRecovery:")
garden = read("MovementForest/Models/GardenModels.swift")
interfaces += block(garden, "enum ForestError:")
wire = read("MovementForest/Models/ActivityAPIModels.swift")
interfaces += wire[wire.index("enum ActivityWire"):wire.index("    static func gameDate")] + "}\n"
models = read("MovementForest/Models/GardenAPIModels.swift")
interfaces += block(models, "struct APIProfileReference:")
interfaces += block(models, "enum ExactAmount")
diagnostics = read("MovementForest/Services/AppDiagnostics.swift")
interfaces += block(diagnostics, "struct GardenFeedback:")
interfaces += block(diagnostics, "enum PlayerMessage")
interfaces += block(read("MovementForest/Services/GardenEffectsCoordinator.swift"), "struct ConfirmedTokenReward:")
interfaces += block(read("MovementForest/Services/AppResumeCoordinator.swift"), "enum LifecycleClock")
interfaces += block(read("MovementForest/Features/Garden/VisitorViews.swift"), "struct VisitorFlightPose:")
interfaces += read("MovementForest/Models/GardenRenderPolicy.swift")
interfaces += read("MovementForestTests/RenderPolicyChecks.swift")
disk = read("MovementForest/Services/AccountDiskStore.swift")
interfaces += disk[disk.index("private struct AccountDiskRecord"):disk.index("struct ConfirmedGardenCache")]
visitor_models = read("MovementForest/Models/VisitorModels.swift")
visitor_models = visitor_models.replace(block(visitor_models, "struct APIVisitorRepository:"), "")
coordinator = read("MovementForest/Services/VisitorCoordinator.swift")
production = interfaces + visitor_models.replace("import Foundation\n", "") + coordinator.replace("import Combine\n", "")

native = read("MovementForestTests/VisitorTests.swift")
header = native[:native.index("@MainActor\nfinal class VisitorTests")]
header = re.sub(r"^(?:import|@testable import) .+\n", "", header, flags=re.M)
header = header.replace(
    'try XCTUnwrap(Bundle.main.url(forResource: "visitor-contract", withExtension: "json", subdirectory: "Fixtures"))',
    'URL(fileURLWithPath: ProcessInfo.processInfo.environment["VISITOR_FIXTURE"]!)',
)
methods = []
for match in re.finditer(r"    func test\w+\(", native):
    method = block(native, match.group())
    if any(name in method for name in ("RealityGardenRenderer", "VisitorModelLibrary", "VisitorGardenOverlay", "VisitorHitTarget")):
        continue
    signature, body = method.split("{", 1)
    # Linux XCTest discovers actor-isolated async cases without a synchronous cast.
    if "async" not in signature:
        signature = signature.replace(" throws ", " ").rstrip() + " async throws "
    methods.append("    " + signature + "{" + body)
helpers = block(native, "    private func waitUntil") + block(native, "    private func releaseHeartbeat")
tests = production + header + "\n@MainActor\nfinal class PortableVisitorTests: XCTestCase {\n" + "\n".join(methods) + helpers + "}\n"
tests += """
final class PortableRenderPolicyTests: XCTestCase {
    func testFixedResolutionAndThermalRecovery() throws {
        XCTAssertEqual(try RenderPolicyChecks.run(), 17)
    }
}
"""
(TESTS / "VisitorTests.swift").write_text(tests, encoding="utf-8")
(OUT / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ForestPerformanceChecks", targets: [
    .testTarget(name: "PerformanceTests", path: "Tests/PerformanceTests")
])
''', encoding="utf-8")
print(f"Prepared {len(methods)} actual visitor scenarios and 17 shared render-policy assertions in {OUT} (no Apple SDK coverage).")
