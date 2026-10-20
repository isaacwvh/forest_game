import Foundation
import CryptoKit

struct PendingGardenEdit: Codable {
    let serverID: String
    let userID: UUID
    let gardenID: UUID
    let body: Data
    var request: GardenEditRequest { get throws { try JSONDecoder().decode(GardenEditRequest.self, from: body) } }
}

protocol PendingEditPersisting {
    func load(server: String, user: UUID) throws -> PendingGardenEdit?
    func save(_ edit: PendingGardenEdit) throws
    func remove(server: String, user: UUID) throws
}

struct PendingGardenEditStore: PendingEditPersisting {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GardenEdits", isDirectory: true)
    }
    private func file(server: String, user: UUID) -> URL {
        let digest = SHA256.hash(data: Data("\(server)|\(user.uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    func load(server: String, user: UUID) throws -> PendingGardenEdit? {
        let url = file(server: server, user: user)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let edit = try JSONDecoder().decode(PendingGardenEdit.self, from: Data(contentsOf: url))
        guard edit.serverID == server, edit.userID == user else {
            throw ForestError.invalidData("The saved edit belongs to another connection.")
        }
        _ = try edit.request
        return edit
    }
    func save(_ edit: PendingGardenEdit) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(edit).write(to: file(server: edit.serverID, user: edit.userID), options: .atomic)
    }
    func remove(server: String, user: UUID) throws {
        let url = file(server: server, user: user)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
