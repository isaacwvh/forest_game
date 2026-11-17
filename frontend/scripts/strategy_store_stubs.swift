// Linux-only interfaces for observation, rendering, diagnostics and persistence.
// The shipped GardenEditorStore itself is included unchanged apart from Combine's import.
protocol ObservableObject: AnyObject { }
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
struct AccountDiskStore {
    init() { }
    func load<T: Decodable>(_ type: T.Type, kind: String, server: String, user: UUID) throws -> T? { nil }
    func save<T: Encodable>(_ value: T, kind: String, server: String, user: UUID) throws { }
    func remove(kind: String, server: String, user: UUID) throws { }
}
struct GardenFeedback {
    enum Kind { case failure, locked, pending, success, uncertain }
    enum Source { case gardenEdit, gardenRead, inventory }
    let id = UUID()
    let text: String
    let kind: Kind
    let source: Source
    var visibleInGarden: Bool { true }
}
final class GardenEffectsCoordinator {
    init(server: String, user: UUID, disk: AccountDiskStore?) { }
    func cancel() { }
    func recordActivity(requestID: UUID, before: APIGarden?, after: APIGarden) { }
}
final class DiagnosticHistory {
    static let shared = DiagnosticHistory()
    static func scope(server: String, user: UUID) -> String { "validation" }
    func record(_ name: String, _ text: String, requestID: String?, scope: String) { }
}
enum PlayerMessage {
    static func failure(_ error: Error, fallback: String) -> String { fallback }
    static func recordFailure(_ name: String, _ error: Error, requestID: String? = nil, scope: String) { }
}
struct APIError: Error { let status: Int; let code: String; let message: String }
struct RequestRecovery: Error {
    struct Outcome { let gardenId: UUID }
    let outcome: Outcome
    func validate(id: UUID, operation: String) throws { }
}
final class PendingGardenEditStore: PendingEditPersisting {
    var value: PendingGardenEdit?
    func load(server: String, user: UUID) throws -> PendingGardenEdit? { value }
    func save(_ edit: PendingGardenEdit) throws { value = edit }
    func remove(server: String, user: UUID) throws { value = nil }
}
