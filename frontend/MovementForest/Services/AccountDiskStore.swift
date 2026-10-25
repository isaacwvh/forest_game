import Foundation
import CryptoKit

private struct AccountDiskRecord<Value> {
    let schemaVersion: Int
    let serverID: String
    let userID: UUID
    let value: Value
}
extension AccountDiskRecord: Encodable where Value: Encodable { }
extension AccountDiskRecord: Decodable where Value: Decodable { }

/// Atomic account/server-scoped files. Health upload journals are excluded from
/// backups, protected on device, and never contain bearer tokens.
struct AccountDiskStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountData", isDirectory: true)
    }
    func file(kind: String, server: String, user: UUID) -> URL {
        let digest = SHA256.hash(data: Data("\(server)|\(user.uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(kind + "-" + digest + ".json")
    }
    func load<T: Decodable>(_ type: T.Type, kind: String, server: String, user: UUID) throws -> T? {
        let url = file(kind: kind, server: server, user: user)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try ActivityWire.decoder().decode(AccountDiskRecord<T>.self, from: Data(contentsOf: url))
        guard record.schemaVersion == 1, record.serverID == server, record.userID == user else {
            throw ForestError.invalidData("The saved data belongs to another account, server, or unsupported format.")
        }
        return record.value
    }
    func save<T: Encodable>(_ value: T, kind: String, server: String, user: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resourceValues)
        let data = try ActivityWire.encoder().encode(AccountDiskRecord(schemaVersion: 1, serverID: server, userID: user, value: value))
        #if os(iOS)
        try data.write(to: file(kind: kind, server: server, user: user),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file(kind: kind, server: server, user: user), options: .atomic)
        #endif
    }
    func remove(kind: String, server: String, user: UUID) throws {
        let url = file(kind: kind, server: server, user: user)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct ConfirmedGardenCache: Codable {
    let serverID: String
    let profile: APIProfile
    let confirmedAt: Date
    let catalogue: APICatalogue
    let garden: APIGarden
    let inventory: [APIOwnedPlant]
    let nextCursor: UUID?
}

struct PendingActivityOperation: Codable, Identifiable {
    enum Kind: String, Codable { case enrolment, sync, acknowledgement }
    let id: UUID
    let kind: Kind
    let body: Data
    let recapID: UUID?
}

struct ActivityJournalState: Codable {
    var expandedInputsEnabled: Bool? = nil
    var enabled = false
    var status: APIActivityStatus?
    var operations: [PendingActivityOperation] = []
    var dismissedRecaps: [UUID] = []
    var lastRejectedRequest: UUID?
    var lastRejectionCode: String?
}

@MainActor
protocol ActivityJournalPersisting {
    func load(server: String, user: UUID) throws -> ActivityJournalState?
    func save(_ state: ActivityJournalState, server: String, user: UUID) throws
}

struct ActivityJournalStore: ActivityJournalPersisting {
    let disk: AccountDiskStore
    init(disk: AccountDiskStore = AccountDiskStore()) { self.disk = disk }
    func load(server: String, user: UUID) throws -> ActivityJournalState? {
        let state = try disk.load(ActivityJournalState.self, kind: "activity", server: server, user: user)
        if let state = state {
            guard Set(state.operations.map(\.id)).count == state.operations.count else {
                throw ForestError.invalidData("The activity journal contains duplicate request IDs.")
            }
            for operation in state.operations {
                let identity = try JSONDecoder().decode(RequestIdentity.self, from: operation.body)
                guard identity.requestId == operation.id,
                      (operation.kind == .acknowledgement) == (operation.recapID != nil) else {
                    throw ForestError.invalidData("The activity journal failed its identity check.")
                }
                switch operation.kind {
                case .enrolment: _ = try ActivityWire.decoder().decode(ActivityEnrolmentRequest.self, from: operation.body)
                case .sync: _ = try ActivityWire.decoder().decode(ActivitySyncRequest.self, from: operation.body)
                case .acknowledgement: break
                }
            }
        }
        return state
    }
    func save(_ state: ActivityJournalState, server: String, user: UUID) throws {
        try disk.save(state, kind: "activity", server: server, user: user)
    }
}

enum InstallationIdentity {
    static func load(disk: AccountDiskStore = AccountDiskStore()) throws -> UUID {
        let url = disk.directory.appendingPathComponent("installation.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: url))
        }
        try FileManager.default.createDirectory(at: disk.directory, withIntermediateDirectories: true)
        let value = UUID()
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        var directory = disk.directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        return value
    }
}
