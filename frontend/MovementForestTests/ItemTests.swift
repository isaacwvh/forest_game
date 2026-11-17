import Foundation
import RealityKit
import XCTest
@testable import MovementForest

private struct ItemsContract: Decodable {
    let profile: APIProfile
    let catalogue: APICatalogue
    let emptyGarden: APIGarden
    let storedInventory: APIItemInventory
    let placedInventory: APIItemInventory
    let placeRequest: GardenEditRequest
    let placeResult: GardenEditResult
    let storeResult: GardenEditResult

    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "items-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private final class ItemEditJournal: PendingEditPersisting {
    var value: PendingGardenEdit?
    func load(server: String, user: UUID) throws -> PendingGardenEdit? { value }
    func save(_ edit: PendingGardenEdit) throws { value = edit }
    func remove(server: String, user: UUID) throws { value = nil }
}

@MainActor
private final class ItemTestService: GardenServing {
    let serverID = "https://items.test"
    let fixture: ItemsContract
    var current: APIGarden
    var bodies: [Data] = []
    var receipts: [UUID: GardenEditResult] = [:]
    var loseResponse = false
    init(_ fixture: ItemsContract) { self.fixture = fixture; current = fixture.emptyGarden }
    func profile() async throws -> APIProfile { fixture.profile }
    func catalogue() async throws -> APICatalogue { fixture.catalogue }
    func garden() async throws -> APIGarden { current }
    func inventory(after: UUID?) async throws -> APIInventory { APIInventory(plants: [], nextCursor: nil) }
    func items(after: UUID?) async throws -> APIItemInventory {
        current.items?.isEmpty == false ? fixture.placedInventory : fixture.storedInventory
    }
    func edit(body: Data) async throws -> GardenEditResult {
        bodies.append(body)
        let request = try JSONDecoder().decode(GardenEditRequest.self, from: body)
        if let receipt = receipts[request.requestId] { return receipt }
        current = request.itemActions?.first?.action == "store" ? fixture.storeResult.garden : fixture.placeResult.garden
        let result = GardenEditResult(requestId: request.requestId, garden: current, updatedPlants: [])
        receipts[request.requestId] = result
        if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        return result
    }
}

@MainActor
final class ItemTests: XCTestCase {
    func testHTTPContractCopiesAndLegacyRequests() throws {
        let fixture = try ItemsContract.load()
        XCTAssertEqual(fixture.storedInventory.items.count, 2)
        XCTAssertEqual(Set(fixture.storedInventory.items.map(\.id)).count, 2)
        XCTAssertEqual(fixture.placeResult.garden.items?.count, 1)
        XCTAssertEqual(fixture.placeResult.garden.totalAttractionMicroUnits, "0")
        let snapshot = try fixture.placeResult.garden.rendered(catalogue: fixture.catalogue, assets: BundleAssetCatalog())
        XCTAssertEqual(snapshot.items?.count, 1); XCTAssertTrue(snapshot.plants.isEmpty)
        let cached = try JSONDecoder().decode(APIGarden.self, from: JSONEncoder().encode(fixture.placeResult.garden))
        XCTAssertEqual(cached, fixture.placeResult.garden)
        let legacy = GardenEditRequest(requestId: UUID(), expectedLayoutVersion: 0,
            catalogVersion: fixture.catalogue.catalogVersion, actions: [])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any])
        XCTAssertNil(encoded["itemActions"], "Do not rewrite old plant-only pending payloads")
    }

    func testPlaceLostResponseReplayStoreAndRelaunch() async throws {
        let fixture = try ItemsContract.load(), service = ItemTestService(fixture), journal = ItemEditJournal()
        let assets = try BundleAssetCatalog()
        let store = GardenEditorStore(profile: fixture.profile, service: service, assets: assets,
            journal: journal, effectHistory: nil)
        await store.start()
        let id = try XCTUnwrap(fixture.placeRequest.itemActions?.first?.itemId)
        let item = try XCTUnwrap(store.itemInventory.first { $0.id == id })
        service.loseResponse = true
        store.beginItem(item, action: "place")
        store.updatePosition(x: 2, y: 2); store.updateRotation(90)
        XCTAssertEqual(store.itemCandidate?.validity, .valid)
        await store.releaseCandidate()
        XCTAssertTrue(service.bodies.isEmpty)
        await store.saveDraft()
        XCTAssertNotNil(store.pending); XCTAssertEqual(store.state, .unknown)
        let savedBody = try XCTUnwrap(journal.value?.body)
        store.deactivate()
        let restored = GardenEditorStore(profile: fixture.profile, service: service, assets: assets,
            journal: journal, effectHistory: nil)
        await restored.start()
        XCTAssertEqual(service.bodies.count, 2)
        XCTAssertEqual(service.bodies[0], service.bodies[1]); XCTAssertEqual(savedBody, service.bodies[1])
        XCTAssertNil(restored.pending); XCTAssertNil(journal.value)
        XCTAssertEqual(restored.confirmed?.items?.first?.id, id)
        XCTAssertEqual(restored.itemInventory.count, 1)
        await restored.storeItem(try XCTUnwrap(restored.confirmed?.items?.first))
        XCTAssertEqual(restored.confirmed?.items?.count, 0)
        XCTAssertEqual(restored.itemInventory.count, 2)
    }

    func testItemPreviewRejectsOverlapBeforeSending() async throws {
        let fixture = try ItemsContract.load(), service = ItemTestService(fixture)
        service.current = fixture.placeResult.garden
        let store = GardenEditorStore(profile: fixture.profile, service: service, assets: try BundleAssetCatalog(),
            journal: ItemEditJournal(), effectHistory: nil)
        await store.start()
        store.beginItem(try XCTUnwrap(store.itemInventory.first), action: "place")
        store.updatePosition(x: 2, y: 2)
        XCTAssertEqual(store.itemCandidate?.validity, .overlap)
        await store.releaseCandidate()
        XCTAssertTrue(service.bodies.isEmpty)
        XCTAssertNil(store.pending)
    }

    func testItemUsesTheSharedEditorPositionAndRotationState() async throws {
        let fixture = try ItemsContract.load(), service = ItemTestService(fixture)
        let store = GardenEditorStore(profile: fixture.profile, service: service, assets: try BundleAssetCatalog(),
            journal: ItemEditJournal(), effectHistory: nil)
        await store.start()
        let item = try XCTUnwrap(store.itemInventory.first)
        store.beginItem(item, action: "place")
        store.updatePosition(x: 3.125, y: 4.25); store.updateRotation(45.5)
        XCTAssertEqual(store.editCandidateID, item.id)
        XCTAssertEqual(store.editCandidateX, Decimal(string: "3.125"))
        XCTAssertEqual(store.editCandidateY, Decimal(string: "4.25"))
        XCTAssertEqual(store.editCandidateRotation, Decimal(string: "45.5"))
        XCTAssertEqual(store.editCandidateValidity, .valid)
        XCTAssertFalse(store.editCandidateIsRotation)
        XCTAssertEqual(store.editCandidateTitle, item.displayName)
        store.cancelCandidate()
        XCTAssertNil(store.editCandidateID)
    }

    func testBenchImportsWithoutWindAndCopiesKeepSeparateAnchors() async throws {
        let fixture = try ItemsContract.load(), renderer = RealityGardenRenderer()
        defer { renderer.stop() }
        var snapshot = try fixture.emptyGarden.rendered(catalogue: fixture.catalogue, assets: BundleAssetCatalog())
        var copies = fixture.storedInventory.items.map { $0.rendered() }
        copies[0].x = 2; copies[0].y = 2; copies[1].x = 6; copies[1].y = 6
        snapshot.items = copies
        renderer.display(snapshot, catalog: try BundleAssetCatalog())
        for _ in 0..<250 {
            if renderer.modelLoadCount == 2 && !renderer.isLoading { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(renderer.modelLoadCount, 2)
        XCTAssertTrue(renderer.errors.isEmpty, renderer.errors.joined(separator: "; "))
        let root = try XCTUnwrap(renderer.view.scene.anchors.first)
        let first = try XCTUnwrap(root.findEntity(named: copies[0].id.uuidString))
        let second = try XCTUnwrap(root.findEntity(named: copies[1].id.uuidString))
        XCTAssertFalse(first === second)
        XCTAssertNotEqual(first.position, second.position)
    }
}
