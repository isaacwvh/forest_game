"""Portable Foundation typecheck and contract checks; never claims Apple SDK coverage.

The shipped expedition models/coordinator and wire date encoder run unchanged.
Only OS observation, disk, Health, HTTP and other coordinators have interfaces.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT.parent / "backend/.local-expedition-validation/native"
OUT.mkdir(parents=True, exist_ok=True)
activity = (ROOT / "MovementForest/Models/ActivityAPIModels.swift").read_text()
wire = activity[activity.index("enum ActivityWire"):activity.index("    static func gameDate")]+"}\n"
workouts = activity[activity.index("struct WorkoutSegmentUpload"):activity.index("struct APIActivityDevice")]
models = (ROOT / "MovementForest/Models/ExpeditionModels.swift").read_text()
coordinator = (ROOT / "MovementForest/Services/ExpeditionCoordinator.swift").read_text().replace("import Combine", "")
collection = (ROOT / "MovementForest/Models/CollectionModels.swift").read_text(encoding="utf-8")
scope = collection[collection.index("enum CollectionReadScope:"):collection.index("@MainActor\nprotocol CollectionServing")]
stubs = r'''
import Foundation
protocol ObservableObject: AnyObject { }
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum ForestError: Error { case invalidData(String) }
struct APIError: Error { let code: String; let message: String }
struct APIClient {
    let baseURL: URL
    @MainActor func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = []) async throws -> T { throw ForestError.invalidData("interface only") }
}
struct AccountDiskStore {
    func load<T: Decodable>(_ type: T.Type, kind: String, server: String, user: UUID) throws -> T? { nil }
    func save<T: Encodable>(_ value: T, kind: String, server: String, user: UUID) throws { }
}
enum InstallationIdentity { static func load(disk: AccountDiskStore) throws -> UUID { UUID() } }
struct Device { let ready: Bool; let installationId: UUID; let deviceId: UUID }
struct Status { let device: Device? }
@MainActor final class ActivitySyncCoordinator { var enabled = true; var status: Status? }
@MainActor protocol HealthDataProviding {
    func readExpeditionEvidence(ranges: [ExpeditionCoverage], now: Date) async throws -> ExpeditionHealthEvidence
}
@MainActor final class ActivityStore {
    let hasRequestedAccess = false
    let provider: any HealthDataProviding
    init(provider: any HealthDataProviding) { self.provider = provider }
}
struct Pending { enum Kind { case expeditionClaim }; let kind: Kind }
struct Receipt { let entitlementId: UUID }
struct State { var pending: Pending?; var result: Receipt? }
@MainActor final class CollectionCoordinator {
    var canMutate = true; var state = State(); var message: String?; var tokenBalance: String?
    func refresh(scope: CollectionReadScope = .full) async { }
    func claimExpedition(run: UUID, entitlement: UUID) async { }
}
'''
checks = r'''
struct Contract: Decodable {
    let initial: ExpeditionRun; let earned: ExpeditionRun; let restored: ExpeditionRun
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let contract = try ActivityWire.decoder().decode(Contract.self, from: data)
_ = try contract.initial.validated(); _ = try contract.earned.validated(); _ = try contract.restored.validated()
precondition(contract.initial.timezone == "UTC")
precondition(contract.earned.completedCount == 9 && contract.earned.quests.allSatisfy { !$0.claimed })
precondition(contract.restored.quests.allSatisfy { $0.claimed })
precondition(contract.earned.rewards.count == 11)
let piece = contract.earned.quests[0].entitlement!.id
let locallyCollected = contract.earned.confirmingClaims([piece])
precondition(locallyCollected.quests[0].claimed && locallyCollected.completedCount == 9)
precondition(locallyCollected.quests.filter { $0.claimed }.count == 1)
let request = UUID(), run = UUID()
let body = ExpeditionEvidenceBody(schemaVersion: 1, requestId: request, deviceId: UUID(), installationId: UUID(),
    observedAt: Date(), days: [], workouts: [])
let saved = PendingExpeditionEvidence(id: request, runID: run, body: try ActivityWire.encoder().encode(body))
let restored = try ActivityWire.decoder().decode(PendingExpeditionEvidence.self, from: ActivityWire.encoder().encode(saved))
precondition(restored.id == request && restored.runID == run && restored.body == saved.body)
var invalid = try JSONSerialization.jsonObject(with: ActivityWire.encoder().encode(contract.earned)) as! [String: Any]
invalid["completedCount"] = 8
do {
    _ = try ActivityWire.decoder().decode(ExpeditionRun.self, from: JSONSerialization.data(withJSONObject: invalid)).validated()
    preconditionFailure("Invalid completion count accepted")
} catch { }
print("PASS: real expedition models and coordinator typecheck with platform interfaces; HTTP fixture, UTC, independent claims, exact pending bytes and invalid-count rejection.")
'''
(OUT / "main.swift").write_text(f"{scope}\n{stubs}\n{wire}\n{workouts}\n{models}\n{coordinator}\n{checks}", encoding="utf-8", newline="\n")
print(OUT / "main.swift")
