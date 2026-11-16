import Foundation
import XCTest
@testable import MovementForest

private struct ItemCommerceContract: Decodable {
    let summary: APICollectionSummary
    let catalogue: APICatalogue
    let purchase: APICollectionReceipt
    let sale: APICollectionReceipt
    let quote: APIItemSaleQuote
    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "item-commerce-contract", withExtension: "json", subdirectory: "Fixtures"))
        return try ActivityWire.decoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@MainActor
private final class ItemCommerceJournal: CollectionJournalPersisting {
    var value = CollectionJournalState()
    var failSave = false
    func load(server: String, user: UUID) throws -> CollectionJournalState? { value }
    func save(_ state: CollectionJournalState, server: String, user: UUID) throws {
        if failSave { throw URLError(.cannotWriteToFile) }
        value = state
    }
}

@MainActor
private final class ItemCommerceService: CollectionServing {
    let serverID = "https://item-commerce.test"
    let fixture: ItemCommerceContract
    var calls: [PendingCollectionOperation] = []
    var receipts: [UUID: APICollectionReceipt] = [:]
    var loseResponse = false
    var balance: String
    var version: Int64
    var capacity: APIItemCapacity?
    var quoteOverride: APIItemSaleQuote?
    var summaryOverride: APICollectionSummary?
    var failSummary = false
    var summaryCalls = 0
    init(_ fixture: ItemCommerceContract) {
        self.fixture = fixture; balance = fixture.summary.tokenBalance
        version = fixture.summary.economyVersion; capacity = fixture.summary.itemCapacity
    }
    func summary() async throws -> APICollectionSummary {
        summaryCalls += 1
        if failSummary { throw URLError(.notConnectedToInternet) }
        if let summary = summaryOverride { return summary }
        return APICollectionSummary(tokenBalance: balance, economyVersion: version, offers: [],
            itemOffers: fixture.summary.itemOffers, itemCapacity: capacity)
    }
    func catalogue() async throws -> APICatalogue { fixture.catalogue }
    func packs(after: UUID?) async throws -> APIPackPage { APIPackPage(packs: [], nextCursor: nil) }
    func openings(after: UUID?) async throws -> APIOpeningPage { APIOpeningPage(openings: [], nextCursor: nil) }
    func definition(pack: String, version: Int) async throws -> APIPackDefinition {
        throw ForestError.invalidData("No pack definitions in item fixture")
    }
    func itemSaleQuote(item: UUID) async throws -> APIItemSaleQuote { quoteOverride ?? fixture.quote }
    func mutate(_ operation: PendingCollectionOperation) async throws -> APICollectionReceipt {
        try operation.validate(); calls.append(operation)
        if let receipt = receipts[operation.id] { return receipt }
        let source: APICollectionReceipt
        switch operation.kind {
        case .itemPurchase: source = fixture.purchase
        case .itemSell: source = fixture.sale
        default: throw ForestError.invalidData("Unexpected operation in item fixture")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ActivityWire.encoder().encode(source)) as? [String: Any])
        object["requestId"] = operation.id.uuidString
        let receipt = try ActivityWire.decoder().decode(APICollectionReceipt.self,
            from: JSONSerialization.data(withJSONObject: object))
        receipts[operation.id] = receipt
        balance = receipt.tokenBalance; version = receipt.economyVersion; capacity = receipt.itemCapacity
        if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        return receipt
    }
}

@MainActor
final class ItemCommerceTests: XCTestCase {
    func testItemPurchaseAcceptsLegacyAndSavedRotationOfferIDs() throws {
        let valid = ["wooden-bench", "garden/2030-01-07/common_1", "garden/2030-01-07/common_2",
                     "garden/2030-01-07/common_3", "garden/2030-01-07/rare", "garden/2030-01-07/epic"]
        let invalid = ["", "garden/2030-01-07/common_4", "garden/2030-01-07/legendary",
                       "garden/2030-01-07/rare/extra", "garden/2030-01-07/../rare", "wooden-bench\n"]
        for offerID in valid + invalid {
            let id = UUID()
            let body = try ActivityWire.encoder().encode(CollectionExchangeBody(requestId: id,
                offerId: offerID, offerVersion: 1, quantity: 1))
            let pending = PendingCollectionOperation(id: id, kind: .itemPurchase, target: nil, body: body)
            if valid.contains(offerID) { XCTAssertNoThrow(try pending.validate(), offerID) }
            else { XCTAssertThrowsError(try pending.validate(), offerID) }
        }
    }

    func testRotatingPurchaseSendsAndRecoversExactRequestAfterRelaunch() async throws {
        struct RotatingContract: Decodable { let summary: APICollectionSummary }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "item-rotations-contract", withExtension: "json", subdirectory: "Fixtures"))
        let rotation = try ActivityWire.decoder().decode(RotatingContract.self, from: Data(contentsOf: url)).summary
        let service = ItemCommerceService(try ItemCommerceContract.load())
        service.summaryOverride = APICollectionSummary(tokenBalance: service.balance, economyVersion: service.version,
            offers: [], itemOffers: rotation.itemOffers, itemCapacity: service.capacity, shop: rotation.shop)
        let journal = ItemCommerceJournal(), user = UUID()
        let first = CollectionCoordinator(userID: user, service: service, journal: journal)
        await first.refresh()
        let offer = try XCTUnwrap(first.itemOffers.first { $0.slot == "common_1" })
        service.loseResponse = true
        await first.buyItem(offer, quantity: 2)
        XCTAssertEqual(service.calls.count, 1)
        let pending = try XCTUnwrap(journal.value.pending)
        let sent = try ActivityWire.decoder().decode(CollectionExchangeBody.self, from: pending.body)
        XCTAssertEqual(sent.offerId, offer.offerId)
        XCTAssertEqual(sent.offerVersion, offer.offerVersion)
        XCTAssertEqual(sent.quantity, 2)
        first.deactivate()
        let restored = CollectionCoordinator(userID: user, service: service, journal: journal)
        await restored.refresh()
        XCTAssertNil(journal.value.pending)
        XCTAssertEqual(service.calls, [pending, pending])
        XCTAssertEqual(service.receipts.count, 1)
    }

    func testHTTPPricesAndWholeTokenResale() throws {
        let value = try ItemCommerceContract.load()
        XCTAssertEqual(value.summary.itemOffers?.first?.tokenCost, "550")
        XCTAssertEqual(value.purchase.tokensSpent, "1100")
        XCTAssertEqual(value.purchase.ownedItemIds?.count, 2)
        XCTAssertEqual(value.quote.tokens, "137")
        XCTAssertEqual(value.sale.tokensEarned, "137")
        XCTAssertEqual(value.sale.tokenBalance, "1037")
    }

    func testPurchaseAndSaleRecoverExactJournalAfterRelaunch() async throws {
        let fixture = try ItemCommerceContract.load(), service = ItemCommerceService(fixture)
        let journal = ItemCommerceJournal(), user = UUID()
        let first = CollectionCoordinator(userID: user, service: service, journal: journal)
        await first.refresh()
        let offer = try XCTUnwrap(first.itemOffers.first)
        service.loseResponse = true
        await first.buyItem(offer, quantity: 2)
        let saved = try XCTUnwrap(journal.value.pending)
        XCTAssertEqual(saved.kind, .itemPurchase)
        first.deactivate()
        let restored = CollectionCoordinator(userID: user, service: service, journal: journal)
        await restored.refresh()
        XCTAssertNil(journal.value.pending)
        XCTAssertEqual(service.calls[0], service.calls[1])
        XCTAssertEqual(restored.tokenBalance, "900")
        let quote = try await restored.itemSaleQuote(item: fixture.quote.ownedItemId)
        service.loseResponse = true
        await restored.sellItem(quote)
        let saleBody = try XCTUnwrap(journal.value.pending?.body)
        await restored.refresh()
        XCTAssertNil(journal.value.pending)
        XCTAssertEqual(service.calls[2].body, saleBody)
        XCTAssertEqual(service.calls[2], service.calls[3])
        XCTAssertEqual(restored.tokenBalance, "1037")
        XCTAssertEqual(restored.itemCapacity?.ownedItems, 1)
    }

    func testFullInventoryAndFailedJournalSendNothing() async throws {
        let service = ItemCommerceService(try ItemCommerceContract.load()), journal = ItemCommerceJournal()
        service.capacity = APIItemCapacity(ownedItems: 50, placedItems: 1, storedItems: 49, itemLimit: 50)
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: journal)
        await store.refresh()
        let offer = try XCTUnwrap(store.itemOffers.first)
        XCTAssertFalse(store.canBuyItem(offer, quantity: 1))
        await store.buyItem(offer, quantity: 1)
        XCTAssertTrue(service.calls.isEmpty)
        service.capacity = APIItemCapacity(ownedItems: 0, placedItems: 0, storedItems: 0, itemLimit: 50)
        await store.refresh()
        journal.failSave = true
        await store.buyItem(offer, quantity: 2)
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testUnverifiedResaleQuoteIsRejected() async throws {
        let fixture = try ItemCommerceContract.load(), service = ItemCommerceService(fixture)
        service.quoteOverride = APIItemSaleQuote(ownedItemId: fixture.quote.ownedItemId,
            valuationVersion: "item-resale-v1", tokenValue: "550", resaleBasisPoints: 2500, tokens: "138")
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: ItemCommerceJournal())
        await store.refresh()
        do {
            _ = try await store.itemSaleQuote(item: fixture.quote.ownedItemId)
            XCTFail("Rounded-up sale quote must not be accepted")
        } catch { }
        XCTAssertTrue(service.calls.isEmpty)
    }

    func testRotatingOfferExpiryAllowanceAndOfflineRefresh() async throws {
        let fixture = try ItemCommerceContract.load(), service = ItemCommerceService(fixture)
        var elapsed: TimeInterval = 100
        let now = Date(timeIntervalSince1970: 1_000_000)
        var offer = try XCTUnwrap(fixture.summary.itemOffers?.first)
        offer.startsAt = now; offer.endsAt = now.addingTimeInterval(10); offer.remainingAllowance = 1
        let rotation = APIShopRotation(serverNow: now, shopTimezone: "UTC", rotationId: "first",
            startsAt: now, endsAt: now.addingTimeInterval(10))
        service.summaryOverride = APICollectionSummary(tokenBalance: service.balance, economyVersion: service.version,
            offers: [], itemOffers: [offer], itemCapacity: service.capacity, shop: rotation)
        let store = CollectionCoordinator(userID: UUID(), service: service, journal: ItemCommerceJournal(), uptime: { elapsed })
        await store.refresh()
        XCTAssertTrue(store.canBuyItem(offer, quantity: 1))
        XCTAssertFalse(store.canBuyItem(offer, quantity: 2))
        elapsed = 110
        XCTAssertFalse(store.canBuyItem(offer, quantity: 1))
        service.failSummary = true
        await store.tickShop()
        XCTAssertTrue(store.refreshFailed)
        XCTAssertEqual(store.shopRemaining, 0)
        let calls = service.summaryCalls
        await store.tickShop()
        XCTAssertEqual(service.summaryCalls, calls, "Offline retries should be bounded")
        service.failSummary = false
        var next = offer; next.endsAt = now.addingTimeInterval(20)
        service.summaryOverride = APICollectionSummary(tokenBalance: service.balance, economyVersion: service.version,
            offers: [], itemOffers: [next], itemCapacity: service.capacity,
            shop: APIShopRotation(serverNow: now.addingTimeInterval(10), shopTimezone: "UTC", rotationId: "next",
                startsAt: now.addingTimeInterval(10), endsAt: now.addingTimeInterval(20)))
        await store.requestShopRefresh()
        XCTAssertTrue(store.canBuyItem(next, quantity: 1))
        XCTAssertFalse(store.canBuyItem(offer, quantity: 1))
        store.deactivate()
        XCTAssertFalse(store.canBuyItem(next, quantity: 1))
    }
}
