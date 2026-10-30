import XCTest
import Foundation
import SwiftUI
import UIKit
import RealityKit
@testable import MovementForest

private struct EditorContract: Decodable {
    let profile: APIProfile
    let catalogue: APICatalogue
    let emptyGarden: APIGarden
    let inventory: APIInventory
    let plantRequest: GardenEditRequest
    let plantResult: GardenEditResult
    let placedInventory: APIInventory
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "editor-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private struct SkillsWireContract: Decodable {
    let catalogue: APICatalogue
    let inventory: APIInventory
    let emptyGarden: APIGarden
    let plantedGarden: APIGarden
    let storedGarden: APIGarden
    let syncResult: APIActivitySyncResult
    let recaps: APIRewardRecaps

    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "skills-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

extension GardenEditorTests {
    func testSleepingDewActualHTTPContractAndCachedRoundTrip() throws {
        let fixture = try SkillsWireContract.load()
        XCTAssertEqual(fixture.emptyGarden.skillSummary?.activeSkills.count, 0)
        XCTAssertEqual(fixture.storedGarden.skillSummary?.activeSkills.count, 0)
        let summary = try XCTUnwrap(fixture.plantedGarden.skillSummary)
        XCTAssertEqual(summary.waterHeadline, "Water +4%")
        XCTAssertFalse(summary.capReached)
        let skill = try XCTUnwrap(summary.activeSkills.first)
        XCTAssertEqual(skill.skillId, "sleeping_dew")
        XCTAssertEqual(skill.name, "Sleeping Dew")
        XCTAssertEqual(skill.bonusText, "+4% water")
        XCTAssertEqual(skill.eligibleSourcePlantIds.count, 1)
        XCTAssertEqual(skill.recipientPlantIds.count, 2)
        XCTAssertEqual(fixture.inventory.plants.first?.growthStage, .adult)
        XCTAssertEqual(fixture.inventory.plants.first?.gardenSkills?.first?.name, "Sleeping Dew")
        XCTAssertEqual(fixture.syncResult.garden.plants.first(where: { $0.speciesId == "oak" })?.growthMicroUnits, "10400000")
        let rendered = try fixture.plantedGarden.rendered(catalogue: fixture.catalogue, assets: BundleAssetCatalog())
        XCTAssertEqual(rendered.plants.count, 2)
        let cached = try JSONDecoder().decode(APIGarden.self, from: JSONEncoder().encode(fixture.plantedGarden))
        XCTAssertEqual(cached.skillSummary, summary)
        let recap = try XCTUnwrap(fixture.recaps.recaps.first?.payload.plants.first)
        XCTAssertEqual(recap.skillBonusGrowthMicroUnits, "400000")
    }

    func testLegacyGardenDoesNotInventSkillStatus() throws {
        let fixture = try EditorContract.load()
        XCTAssertNil(fixture.emptyGarden.skillSummary)
        XCTAssertNil(fixture.inventory.plants.first?.gardenSkills)
    }
}

private final class MemoryEditJournal: PendingEditPersisting {
    var edits: [String: PendingGardenEdit] = [:]
    var failSave = false
    var failLoad = false
    var failRemove = false
    func load(server: String, user: UUID) throws -> PendingGardenEdit? {
        if failLoad { throw URLError(.cannotDecodeContentData) }
        return edits[server + user.uuidString]
    }
    func save(_ edit: PendingGardenEdit) throws {
        if failSave { throw URLError(.cannotWriteToFile) }
        edits[edit.serverID + edit.userID.uuidString] = edit
    }
    func remove(server: String, user: UUID) throws {
        if failRemove { throw URLError(.cannotWriteToFile) }
        edits.removeValue(forKey: server + user.uuidString)
    }
}

@MainActor
private final class EditorTestService: GardenServing {
    var serverID = "https://garden.test"
    let fixture: EditorContract
    var current: APIGarden
    var catalogueValue: APICatalogue
    var receipts: [UUID: GardenEditResult] = [:]
    var bodies: [Data] = []
    var loseNextResponse = false
    var nextError: APIError?
    var compactError: RequestRecovery?
    var failReads = false
    var pauseNext = false
    var pauseRead = false
    var gate: CheckedContinuation<Void, Never>?
    var extraInventory: [APIOwnedPlant] = []
    var pages: [String: APIInventory] = [:]
    var pauseInventory = false
    var inventoryGate: CheckedContinuation<Void, Never>?

    init(_ fixture: EditorContract) {
        self.fixture = fixture; current = fixture.emptyGarden; catalogueValue = fixture.catalogue
    }
    func profile() async throws -> APIProfile { fixture.profile }
    func catalogue() async throws -> APICatalogue {
        if pauseRead { pauseRead = false; await withCheckedContinuation { gate = $0 } }
        if failReads { throw URLError(.notConnectedToInternet) }
        return catalogueValue
    }
    func garden() async throws -> APIGarden { current }
    func inventory(after: UUID?) async throws -> APIInventory {
        if pauseInventory { pauseInventory = false; await withCheckedContinuation { inventoryGate = $0 } }
        if let page = pages[after?.uuidString ?? "first"] { return page }
        let placed = Set(current.plants.map(\.id))
        let copies = fixture.inventory.plants + extraInventory
        return APIInventory(plants: copies.filter { !placed.contains($0.id) }, nextCursor: nil)
    }
    func edit(body: Data) async throws -> GardenEditResult {
        bodies.append(body)
        if pauseNext { pauseNext = false; await withCheckedContinuation { gate = $0 } }
        if let error = nextError { nextError = nil; throw error }
        if let error = compactError { compactError = nil; throw error }
        let request = try JSONDecoder().decode(GardenEditRequest.self, from: body)
        if let result = receipts[request.requestId] { return result }
        guard request.expectedLayoutVersion == current.layoutVersion else {
            throw APIError(status: 409, code: "stale_layout", message: "Refresh the garden before editing")
        }
        let action = try XCTUnwrap(request.actions.first)
        let plant = try XCTUnwrap((current.plants + fixture.inventory.plants + extraInventory).first { $0.id == action.plantId })
        let placement: APIPlacement? = action.action == .store ? nil : APIPlacement(
            gardenId: current.gardenId, x: action.x ?? plant.placement?.x ?? 0,
            y: action.y ?? plant.placement?.y ?? 0, rotationDegrees: action.rotationDegrees ?? plant.placement?.rotationDegrees ?? 0)
        let updated = APIOwnedPlant(plantId: plant.id, speciesId: plant.speciesId, variantId: plant.variantId,
                                    growthMicroUnits: plant.growthMicroUnits, growthStage: plant.growthStage,
                                    modelKey: plant.modelKey, thumbnailKey: plant.thumbnailKey, placement: placement)
        var plants = current.plants.filter { $0.id != plant.id }
        if placement != nil { plants.append(updated) }
        current = APIGarden(gardenId: current.gardenId, width: current.width, depth: current.depth,
                            coordinateUnit: current.coordinateUnit, gardenUnitMetres: current.gardenUnitMetres,
                            catalogVersion: current.catalogVersion, layoutVersion: current.layoutVersion + 1,
                            stateVersion: current.stateVersion + 1, plants: plants)
        let result = GardenEditResult(requestId: request.requestId, garden: current, updatedPlants: [updated])
        receipts[request.requestId] = result
        if loseNextResponse { loseNextResponse = false; throw URLError(.networkConnectionLost) }
        return result
    }
}

@MainActor
final class GardenEditorTests: XCTestCase {
    func testCompactEditCompletionRefreshesCurrentLayoutWithoutResubmission() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        let journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start()
        service.loseNextResponse = true
        store.begin(try XCTUnwrap(fixture.inventory.plants.first), kind: .plant)
        store.updatePosition(x: 2, y: 2)
        await store.releaseCandidate()
        let pending = try XCTUnwrap(store.pending)
        let id = try pending.request.requestId
        service.compactError = RequestRecovery(version: 1, status: "completed", requestId: id,
            operation: "garden_edits", acceptedAt: Date(),
            outcome: .init(gardenId: fixture.emptyGarden.gardenId, controlSequence: nil, visits: nil, tokens: nil), refreshRequired: true)
        let layout = service.current.layoutVersion
        await store.retryPending()
        XCTAssertNil(store.pending)
        XCTAssertEqual(service.current.layoutVersion, layout)
        XCTAssertEqual(store.confirmed?.layoutVersion, layout)
        XCTAssertEqual(service.bodies, [pending.body, pending.body])
    }

    func testConnectedPopupAttractionAndRecoveryPreserveViewportCameraAndImports() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        service.current = fixture.plantResult.garden
        let store = try makeStore(service), catalog = try BundleAssetCatalog()
        await store.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ConnectedGardenScreen(store: store, catalog: catalog, active: true))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<1500 {
            if let renderer = LiveGardenDiagnostics.shared.renderer, renderer.view.window === window,
               renderer.modelLoadCount == 1, !renderer.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let renderer = try XCTUnwrap(LiveGardenDiagnostics.shared.renderer)
        XCTAssertTrue(renderer.view.window === window)
        XCTAssertEqual(renderer.modelLoadCount, 1)
        renderer.zoom(by: 0.8)
        let camera = try XCTUnwrap(renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first)
        let bounds = renderer.view.bounds, position = camera.position, rotation = camera.orientation.vector
        let id = try XCTUnwrap(store.confirmed?.plants.first?.id)
        for selected in [id, nil, id] {
            store.selectedID = selected
            service.current.totalAttractionMicroUnits = selected == nil ? "0" : "123000000"
            try store.applyConfirmed(service.current)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(renderer.view.bounds, bounds)
            XCTAssertEqual(camera.position, position); XCTAssertEqual(camera.orientation.vector, rotation)
            XCTAssertEqual(renderer.modelLoadCount, 1)
            XCTAssertNil(store.candidate); XCTAssertTrue(service.bodies.isEmpty)
        }
        service.failReads = true; await store.refresh()
        XCTAssertNotNil(store.gardenMessage)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(renderer.view.bounds, bounds); XCTAssertEqual(camera.position, position)
        service.failReads = false; await store.refresh()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(store.gardenMessage)
        XCTAssertEqual(renderer.view.bounds, bounds); XCTAssertEqual(camera.orientation.vector, rotation)
        XCTAssertEqual(renderer.modelLoadCount, 1)
        renderer.stop()
    }

    func testConfirmedStorageClearsGardenSelectionEvenWhileTheCopyRemainsOwned() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        service.current = fixture.plantResult.garden
        let store = try makeStore(service)
        await store.start()
        let id = try XCTUnwrap(store.confirmed?.plants.first?.id)
        store.selectedID = id
        XCTAssertEqual(store.selectedPlanted?.id, id)
        let current = service.current
        service.current = APIGarden(gardenId: current.gardenId, width: current.width, depth: current.depth,
            coordinateUnit: current.coordinateUnit, gardenUnitMetres: current.gardenUnitMetres,
            catalogVersion: current.catalogVersion, layoutVersion: current.layoutVersion + 1,
            stateVersion: current.stateVersion + 1, plants: [])
        await store.refresh()
        XCTAssertNil(store.selectedID); XCTAssertNil(store.selectedPlanted)
        XCTAssertNotNil(store.ownedCopy(id)); XCTAssertNil(store.candidate)
        XCTAssertTrue(service.bodies.isEmpty)
    }

    func testGardenSelectionResolvesDuplicateCopiesByIdentityWithoutEditing() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        let first = try XCTUnwrap(fixture.plantResult.garden.plants.first)
        let placement = try XCTUnwrap(first.placement)
        let second = APIOwnedPlant(plantId: UUID(), speciesId: first.speciesId, variantId: first.variantId,
            growthMicroUnits: "1", growthStage: first.growthStage, modelKey: first.modelKey,
            thumbnailKey: first.thumbnailKey, placement: APIPlacement(gardenId: placement.gardenId,
                x: placement.x + 3, y: placement.y, rotationDegrees: placement.rotationDegrees))
        let garden = fixture.plantResult.garden
        service.current = APIGarden(gardenId: garden.gardenId, width: garden.width, depth: garden.depth,
            coordinateUnit: garden.coordinateUnit, gardenUnitMetres: garden.gardenUnitMetres,
            catalogVersion: garden.catalogVersion, layoutVersion: garden.layoutVersion,
            stateVersion: garden.stateVersion, plants: [first, second])
        let store = try makeStore(service)
        await store.start()
        for copy in [first, second] {
            store.selectedID = copy.id
            XCTAssertEqual(store.selectedPlanted?.id, copy.id)
            XCTAssertEqual(store.ownedCopy(copy.id)?.growthMicroUnits, copy.growthMicroUnits)
            XCTAssertEqual(store.render(try XCTUnwrap(store.selectedPlanted))?.id, copy.id)
        }
        XCTAssertFalse(store.editing); XCTAssertNil(store.candidate); XCTAssertTrue(service.bodies.isEmpty)
        store.deactivate()
        XCTAssertNil(store.selectedID)
    }

    func testConfirmedGardenRemainsVisitorEligibleDuringReadOnlyRefresh() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(fixture)
        let store = try makeStore(service)
        XCTAssertFalse(store.canPresentVisitors)
        await store.start()
        XCTAssertTrue(store.canPresentVisitors)
        service.pauseRead = true
        let refresh = Task { await store.refresh() }
        for _ in 0..<1000 where service.gate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let gate = try XCTUnwrap(service.gate)
        XCTAssertEqual(store.state, .loading)
        XCTAssertTrue(store.canPresentVisitors)
        store.editing = true
        XCTAssertFalse(store.canPresentVisitors)
        store.editing = false
        gate.resume(); service.gate = nil; await refresh.value
        service.failReads = true; await store.refresh()
        XCTAssertFalse(store.canPresentVisitors, "Offline cached viewing must pause active visitors")
    }

    private func makeStore(_ service: EditorTestService, journal: MemoryEditJournal = MemoryEditJournal()) throws -> GardenEditorStore {
        GardenEditorStore(profile: service.fixture.profile, service: service, assets: try BundleAssetCatalog(), journal: journal)
    }

    func testBackendWireFixtureMapsOwnershipAssetsAndNestedPlacement() throws {
        let fixture = try EditorContract.load()
        let assets = try BundleAssetCatalog()
        let garden = try fixture.plantResult.garden.rendered(catalogue: fixture.catalogue, assets: assets)
        let plant = try XCTUnwrap(garden.plants.first)
        XCTAssertEqual(plant.id, fixture.inventory.plants.first?.id)
        XCTAssertEqual(plant.x, 3.201, accuracy: 0.000001)
        XCTAssertEqual(plant.y, 4.609, accuracy: 0.000001)
        XCTAssertEqual(plant.rotationDegrees, 35.12, accuracy: 0.000001)
        XCTAssertEqual(plant.assetVersion, "1.0.0")
        _ = try assets.resolve(plant)
        XCTAssertNil(fixture.inventory.plants.first?.placement)
        XCTAssertEqual(fixture.inventory.plants.first?.growthMicroUnits, "0")
        XCTAssertFalse(garden.isSample)
    }

    func testRequestEncodingPreservesNumericPrecisionAndOmitsAbsentFields() throws {
        let fixture = try EditorContract.load()
        let action = GardenEditAction(action: .move, plantId: fixture.plantRequest.actions[0].plantId,
                                      x: Decimal(string: "3.201"), y: Decimal(string: "4.609"))
        let request = GardenEditRequest(requestId: UUID(), expectedLayoutVersion: 1,
                                        catalogVersion: fixture.catalogue.catalogVersion, actions: [action])
        let data = try request.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
        XCTAssertTrue(actions[0]["x"] is NSNumber)
        XCTAssertNil(actions[0]["rotationDegrees"])
        XCTAssertEqual(try JSONDecoder().decode(GardenEditRequest.self, from: data), request)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("3.201"))
    }

    func testPlaceMoveRotateStoreAndReplantKeepTheSameCopy() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        let store = try makeStore(service)
        await store.start()
        let copy = try XCTUnwrap(store.inventory.first)
        store.begin(copy, kind: .plant)
        store.updatePosition(x: 3.201, y: 4.609)
        await store.releaseCandidate()
        XCTAssertEqual(store.confirmed?.plants.first?.id, copy.id)
        XCTAssertEqual(store.feedback?.kind, .success)
        XCTAssertNil(store.gardenMessage)
        XCTAssertEqual(store.message, "Saved.")
        XCTAssertTrue(store.inventory.isEmpty)
        store.begin(try XCTUnwrap(store.confirmed?.plants.first), kind: .move)
        store.updatePosition(x: 5.001, y: 6.002)
        await store.releaseCandidate()
        XCTAssertEqual(store.confirmed?.plants.first?.placement?.x, Decimal(string: "5.001"))
        store.begin(try XCTUnwrap(store.confirmed?.plants.first), kind: .rotate)
        store.updateRotation(359.99)
        await store.releaseCandidate()
        XCTAssertEqual(store.confirmed?.plants.first?.placement?.rotationDegrees, Decimal(string: "359.99"))
        store.selectedID = copy.id
        await store.storeSelected()
        XCTAssertTrue(store.confirmed?.plants.isEmpty == true)
        XCTAssertEqual(store.inventory.first?.id, copy.id)
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertEqual(store.confirmed?.plants.first?.growthMicroUnits, fixture.inventory.plants.first?.growthMicroUnits)
        XCTAssertEqual(store.confirmed?.plants.first?.id, copy.id)
        XCTAssertEqual(store.confirmed?.layoutVersion, 5)
    }

    func testInvalidAndCancelledCandidatesSendNothing() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start()
        let copy = try XCTUnwrap(store.inventory.first)
        store.begin(copy, kind: .plant); store.updatePosition(x: 0.899, y: 2)
        XCTAssertEqual(store.candidate?.validity, .outOfBounds)
        await store.releaseCandidate()
        XCTAssertTrue(service.bodies.isEmpty); XCTAssertTrue(journal.edits.isEmpty)
        store.begin(copy, kind: .plant); store.cancelCandidate()
        await store.releaseCandidate()
        XCTAssertTrue(service.bodies.isEmpty)
    }

    func testLostResponseAndRelaunchReplayIdenticalBytesOnce() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let original = try makeStore(service, journal: journal)
        await original.start()
        service.loseNextResponse = true
        original.begin(try XCTUnwrap(original.inventory.first), kind: .plant)
        await original.releaseCandidate()
        XCTAssertEqual(original.state, .unknown)
        XCTAssertEqual(original.feedback?.kind, .uncertain)
        XCTAssertNotNil(original.gardenMessage)
        XCTAssertFalse(original.canEdit)
        XCTAssertEqual(service.current.layoutVersion, 1)
        let restored = try makeStore(service, journal: journal)
        await restored.start()
        XCTAssertEqual(service.bodies.count, 2)
        XCTAssertEqual(service.bodies[0], service.bodies[1])
        XCTAssertEqual(restored.confirmed?.layoutVersion, 1)
        XCTAssertTrue(journal.edits.isEmpty)
        XCTAssertTrue(restored.canEdit)
    }

    func testJournalFailurePreventsTransmissionAndCorruptionBlocksRefresh() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start(); journal.failSave = true
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertTrue(service.bodies.isEmpty)
        journal.failLoad = true
        let restored = try makeStore(service, journal: journal)
        await restored.start(); await restored.refresh()
        XCTAssertTrue(restored.recoveryLocked)
        XCTAssertFalse(restored.canEdit)
    }

    func testExpiredTokenKeepsRequestAndReplacementResumesIt() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start()
        service.nextError = APIError(status: 401, code: "invalid_token", message: "Expired")
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertEqual(store.state, .authenticationRequired)
        XCTAssertFalse(journal.edits.isEmpty)
        await store.replaceService(service)
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(service.bodies[0], service.bodies[1])
    }

    func testDefinitiveRejectionRefreshesWithoutReapplyingCandidate() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start()
        service.nextError = APIError(status: 409, code: "stale_layout", message: "Refresh the garden")
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertNil(store.pending); XCTAssertNil(store.candidate)
        XCTAssertTrue(store.confirmed?.plants.isEmpty == true)
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(service.bodies.count, 1)
    }

    func testSuccessfulReceiptWithFailedRefreshDoesNotEnableStaleEditing() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start()
        service.failReads = true
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertNil(store.pending)
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(store.confirmed?.layoutVersion, 1)
        service.failReads = false; await store.refresh()
        XCTAssertTrue(store.canEdit)
    }

    func testOverlappingSubmissionsAreSerialized() async throws {
        let service = EditorTestService(try EditorContract.load())
        let store = try makeStore(service)
        await store.start()
        service.pauseNext = true
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        let first = Task { await store.releaseCandidate() }
        for _ in 0..<100 where service.gate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(store.state, .saving)
        await store.releaseCandidate()
        XCTAssertEqual(service.bodies.count, 1)
        let gate = try XCTUnwrap(service.gate)
        gate.resume(); service.gate = nil
        await first.value
        XCTAssertEqual(store.confirmed?.layoutVersion, 1)
    }

    func testLogoutDuringEditRetainsReceiptRequestUntilTheAccountReturns() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start(); service.pauseNext = true
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        let pending = Task { await store.releaseCandidate() }
        for _ in 0..<1000 where service.gate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let body = try XCTUnwrap(store.pending?.body)
        store.deactivate()
        let gate = try XCTUnwrap(service.gate); gate.resume(); service.gate = nil
        await pending.value
        XCTAssertEqual(store.confirmed?.layoutVersion, 0)
        XCTAssertEqual(store.pending?.body, body)
        let restored = try makeStore(service, journal: journal)
        await restored.start()
        XCTAssertEqual(service.bodies, [body, body])
        XCTAssertNil(restored.pending)
        XCTAssertEqual(restored.confirmed?.layoutVersion, 1)
    }

    func testJournalSeparatesAccountsAndServersAndSurvivesRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forest-editor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try EditorContract.load()
        let edit = PendingGardenEdit(serverID: "https://one.test", userID: fixture.profile.userId,
                                     gardenID: fixture.emptyGarden.gardenId, body: try fixture.plantRequest.encoded())
        try PendingGardenEditStore(directory: directory).save(edit)
        let reopened = PendingGardenEditStore(directory: directory)
        XCTAssertEqual(try reopened.load(server: edit.serverID, user: edit.userID)?.body, edit.body)
        XCTAssertNil(try reopened.load(server: "https://two.test", user: edit.userID))
        XCTAssertNil(try reopened.load(server: edit.serverID, user: UUID()))
    }

    func testInventoryPaginationDeduplicatesAndExcludesPlacedCopies() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        let first = try XCTUnwrap(fixture.inventory.plants.first)
        let second = APIOwnedPlant(plantId: UUID(), speciesId: first.speciesId, variantId: first.variantId,
                                   growthMicroUnits: "0", growthStage: first.growthStage, modelKey: first.modelKey,
                                   thumbnailKey: first.thumbnailKey, placement: nil)
        service.pages["first"] = APIInventory(plants: [first, first], nextCursor: first.id)
        service.pages[first.id.uuidString] = APIInventory(plants: [first, second, second], nextCursor: nil)
        let store = try makeStore(service)
        await store.start(); await store.loadMore()
        XCTAssertEqual(store.inventory.map(\.id), [first.id, second.id])
        XCTAssertNil(store.nextCursor)
    }

    func testReadOnlyPaginationWorksWhileActivityBlocksEditing() async throws {
        let service = EditorTestService(try EditorContract.load()), store = try makeStore(service)
        let first = try XCTUnwrap(service.fixture.inventory.plants.first)
        let next = APIOwnedPlant(plantId: UUID(), speciesId: first.speciesId, variantId: first.variantId,
            growthMicroUnits: "0", growthStage: first.growthStage, modelKey: first.modelKey, thumbnailKey: first.thumbnailKey, placement: nil)
        service.pages["first"] = APIInventory(plants: [first], nextCursor: first.id)
        service.pages[first.id.uuidString] = APIInventory(plants: [first, next], nextCursor: nil)
        await store.start(); store.activityBlocked = true
        XCTAssertFalse(store.canEdit); XCTAssertTrue(store.canReadInventory)
        await store.loadMore()
        XCTAssertEqual(Set(store.inventory.map(\.id)), Set([first.id, next.id]))
        XCTAssertTrue(service.bodies.isEmpty)
    }

    func testInventoryPageCannotMergeAfterRefreshInvalidatesItsCursor() async throws {
        let service = EditorTestService(try EditorContract.load()), store = try makeStore(service)
        let first = try XCTUnwrap(service.fixture.inventory.plants.first)
        let stale = APIOwnedPlant(plantId: UUID(), speciesId: first.speciesId, variantId: first.variantId,
            growthMicroUnits: "0", growthStage: first.growthStage, modelKey: first.modelKey, thumbnailKey: first.thumbnailKey, placement: nil)
        service.pages["first"] = APIInventory(plants: [first], nextCursor: first.id)
        service.pages[first.id.uuidString] = APIInventory(plants: [stale], nextCursor: nil)
        await store.start(); service.pauseInventory = true
        let read = Task { await store.loadMore() }
        for _ in 0..<1000 where service.inventoryGate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let gate = try XCTUnwrap(service.inventoryGate)
        await store.refresh(); gate.resume(); await read.value
        XCTAssertEqual(store.inventory.map(\.id), [first.id]); XCTAssertEqual(store.nextCursor, first.id)
        XCTAssertTrue(service.bodies.isEmpty)
    }

    func testDoneDuringActivityPreflightDoesNotSubmitTheCancelledEdit() async throws {
        let service = EditorTestService(try EditorContract.load()), store = try makeStore(service)
        await store.start(); store.editing = true
        var gate: CheckedContinuation<Bool, Never>?
        store.prepareMembershipChange = { await withCheckedContinuation { gate = $0 } }
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        let save = Task { await store.releaseCandidate() }
        for _ in 0..<1000 where gate == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let continuation = try XCTUnwrap(gate)
        store.endEditing(); continuation.resume(returning: true); await save.value
        XCTAssertTrue(service.bodies.isEmpty); XCTAssertNil(store.pending); XCTAssertNil(store.candidate)
        XCTAssertFalse(store.editing)
    }

    func testActivityPreflightMayClearPreviewWithoutCancellingTheSubmittedIntent() async throws {
        let service = EditorTestService(try EditorContract.load()), store = try makeStore(service)
        await store.start()
        store.prepareMembershipChange = {
            XCTAssertTrue(store.beginActivityOperation()); store.endActivityOperation(); return true
        }
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertEqual(service.bodies.count, 1); XCTAssertEqual(store.confirmed?.plants.count, 1)
    }

    func testDonePreservesUnknownRequestAndRetryUsesTheSameBytes() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start(); store.editing = true; service.loseNextResponse = true
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant); await store.releaseCandidate()
        let saved = try XCTUnwrap(store.pending)
        store.endEditing()
        XCTAssertEqual(store.pending?.body, saved.body); XCTAssertFalse(store.editing)
        await store.retryPending()
        XCTAssertEqual(service.bodies.count, 2); XCTAssertEqual(service.bodies[0], service.bodies[1])
        XCTAssertEqual(service.receipts.count, 1); XCTAssertNil(store.pending)
    }

    func testReplayReceiptCannotHideNewerServerLayout() async throws {
        let fixture = try EditorContract.load(), service = EditorTestService(try EditorContract.load())
        let journal = MemoryEditJournal()
        // Use the same journal for the relaunch, just as the file-backed implementation does.
        let original = try makeStore(service, journal: journal)
        await original.start(); service.loseNextResponse = true
        original.begin(try XCTUnwrap(original.inventory.first), kind: .plant)
        await original.releaseCandidate()
        let plant = try XCTUnwrap(service.current.plants.first)
        let changed = APIOwnedPlant(plantId: plant.id, speciesId: plant.speciesId, variantId: plant.variantId,
                                    growthMicroUnits: plant.growthMicroUnits, growthStage: plant.growthStage,
                                    modelKey: plant.modelKey, thumbnailKey: plant.thumbnailKey,
                                    placement: APIPlacement(gardenId: service.current.gardenId, x: 7, y: 7, rotationDegrees: 90))
        service.current = APIGarden(gardenId: service.current.gardenId, width: service.current.width,
                                    depth: service.current.depth, coordinateUnit: "garden_unit", gardenUnitMetres: 1,
                                    catalogVersion: fixture.catalogue.catalogVersion, layoutVersion: 2, stateVersion: 2, plants: [changed])
        let restored = try makeStore(service, journal: journal)
        await restored.start()
        XCTAssertEqual(restored.confirmed?.layoutVersion, 2)
        XCTAssertEqual(restored.confirmed?.plants.first?.placement?.x, 7)
        XCTAssertNil(restored.pending)
    }

    func testReceiptCleanupFailureRetainsRequestUntilItCanBeReplayed() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start(); journal.failRemove = true
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertEqual(store.state, .unknown)
        XCTAssertNotNil(store.pending)
        journal.failRemove = false; await store.retryPending()
        XCTAssertEqual(service.current.layoutVersion, 1)
        XCTAssertTrue(store.canEdit)
    }

    func testIdempotencyConflictStopsRetriesAndDoesNotDiscardTheRequest() async throws {
        let service = EditorTestService(try EditorContract.load()), journal = MemoryEditJournal()
        let store = try makeStore(service, journal: journal)
        await store.start()
        service.nextError = APIError(status: 409, code: "idempotency_conflict", message: "Conflict")
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate(); await store.retryPending()
        XCTAssertTrue(store.recoveryLocked)
        XCTAssertNotNil(store.pending)
        XCTAssertEqual(service.bodies.count, 1)
    }

    func testStateOnlyUpdatesDoNotBecomeLayoutPreconditions() async throws {
        let service = EditorTestService(try EditorContract.load())
        let garden = service.current
        service.current = APIGarden(gardenId: garden.gardenId, width: garden.width, depth: garden.depth,
                                    coordinateUnit: garden.coordinateUnit, gardenUnitMetres: garden.gardenUnitMetres,
                                    catalogVersion: garden.catalogVersion, layoutVersion: 0, stateVersion: 99, plants: [])
        let store = try makeStore(service)
        await store.start()
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        let request = try JSONDecoder().decode(GardenEditRequest.self, from: XCTUnwrap(service.bodies.first))
        XCTAssertEqual(request.expectedLayoutVersion, 0)
        XCTAssertEqual(store.confirmed?.stateVersion, 100)
        XCTAssertTrue(store.canEdit)
    }

    func testFailedActivityPreflightPreventsMembershipMutation() async throws {
        let service = EditorTestService(try EditorContract.load()), store = try makeStore(service)
        await store.start()
        var preflights = 0
        store.prepareMembershipChange = { preflights += 1; return false }
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        XCTAssertEqual(preflights, 1); XCTAssertTrue(service.bodies.isEmpty)
        XCTAssertNil(store.pending); XCTAssertTrue(store.canEdit)
    }

    func testSuccessfulActivityPreflightUsesLatestConfirmedState() async throws {
        let service = EditorTestService(try EditorContract.load()), store = try makeStore(service)
        await store.start()
        var preflights = 0
        store.prepareMembershipChange = { preflights += 1; return true }
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        await store.releaseCandidate()
        store.begin(try XCTUnwrap(store.confirmed?.plants.first), kind: .move)
        store.updatePosition(x: 6, y: 6); await store.releaseCandidate()
        XCTAssertEqual(preflights, 1) // A transform-only change does not change membership.
        store.selectedID = store.confirmed?.plants.first?.id
        await store.storeSelected()
        XCTAssertEqual(preflights, 2)
        XCTAssertEqual(service.bodies.count, 3)
    }

    func testStaleCatalogueRefreshesRulesAndRequiresANewEdit() async throws {
        let service = EditorTestService(try EditorContract.load())
        let store = try makeStore(service)
        await store.start()
        store.begin(try XCTUnwrap(store.inventory.first), kind: .plant)
        let catalog = service.catalogueValue, garden = service.current
        service.catalogueValue = APICatalogue(catalogVersion: "new-rules", isFixture: true,
                                              coordinateUnit: catalog.coordinateUnit, gardenUnitMetres: catalog.gardenUnitMetres,
                                              coordinateDecimalPlaces: 3, rotationDecimalPlaces: 2, species: catalog.species)
        service.current = APIGarden(gardenId: garden.gardenId, width: garden.width, depth: garden.depth,
                                    coordinateUnit: garden.coordinateUnit, gardenUnitMetres: garden.gardenUnitMetres,
                                    catalogVersion: "new-rules", layoutVersion: 0, stateVersion: 0, plants: [])
        service.nextError = APIError(status: 409, code: "stale_catalogue", message: "Refresh the catalogue")
        await store.releaseCandidate()
        XCTAssertEqual(store.catalogue?.catalogVersion, "new-rules")
        XCTAssertNil(store.candidate)
        XCTAssertEqual(service.bodies.count, 1)
        XCTAssertTrue(store.canEdit)
    }
}

final class PlacementGeometryTests: XCTestCase {
    private struct FixtureFile: Decodable {
        struct Case: Decodable {
            struct Plant: Decodable { let id: String; let x: Decimal; let y: Decimal; let radius: Decimal }
            let name: String; let width: Decimal; let depth: Decimal; let plants: [Plant]; let error: String?
        }
        let cases: [Case]
    }
    func testSharedBackendGeometryFixtures() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "placement-cases", withExtension: "json"))
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 12)
        for item in fixture.cases {
            let circles = try item.plants.map {
                PlacementCircle(id: UUID(), x: try PlacementGeometry.units($0.x), y: try PlacementGeometry.units($0.y),
                                radius: try PlacementGeometry.units($0.radius))
            }
            let result = try PlacementGeometry.validate(width: PlacementGeometry.units(item.width),
                                                        depth: PlacementGeometry.units(item.depth), circles: circles)
            let expected: PlacementValidity = item.error == nil ? .valid : (item.error == "out_of_bounds" ? .outOfBounds : .overlap)
            XCTAssertEqual(result, expected, item.name)
        }
    }
    func testCanonicalPrecisionWrappingAndOverflowBounds() throws {
        XCTAssertEqual(PlacementGeometry.canonical(3.20149), Decimal(string: "3.201"))
        XCTAssertEqual(PlacementGeometry.rotation(359.999), 0)
        XCTAssertEqual(PlacementGeometry.rotation(-0.01), Decimal(string: "359.99"))
        XCTAssertNil(PlacementGeometry.canonical(.nan))
        XCTAssertThrowsError(try PlacementGeometry.units(Decimal(string: "3.2011")!))
        let large = PlacementCircle(id: UUID(), x: 500_000_000, y: 500_000_000, radius: 999_999_999)
        XCTAssertEqual(PlacementGeometry.validate(width: 999_999_999, depth: 999_999_999, circles: [large]), .outOfBounds)
    }
}
