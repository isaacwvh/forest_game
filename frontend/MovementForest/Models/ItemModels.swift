import Foundation

enum ItemDescriptionCopy {
    // Trim notes from the released copy without rewriting immutable definitions.
    // Exact suffixes preserve new/unknown descriptions and additional flavor text.
    static func concise(_ description: String) -> String {
        let notes = [
            " Static, cosmetic decoration; no gameplay skill or base attraction.",
            " Static and cosmetic; no gameplay skill or base attraction.",
            " Static cosmetic item. No skill.",
            " Cosmetic; no gameplay skill.",
            " +5% offline visitor storage capacity while placed.",
            " +3% garden attraction while placed. Gentle honey drip.",
            " Morning Rain gives each planted plant +2.5 water at the start of each game day.",
            " Celestial Welcome gives +4.5% garden attraction while placed.",
            " Sporeline Surge gives all planted plants +4% water from workouts while placed.",
            " Gentle six-second wind loop. Gentle Hold extends butterfly welcome time by 20% while placed.",
            " Borrowed Wisdom gives +1% activity water per distinct planted species, capped at +5%."
        ]
        guard let note = notes.first(where: { description.hasSuffix($0) }) else { return description }
        return String(description.dropLast(note.count))
    }
}

struct APIItemSkill: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
}

struct APIShopRotation: Codable {
    let serverNow: Date
    let shopTimezone: String
    let rotationId: String
    let startsAt: Date
    let endsAt: Date
}

struct ShopCountdown {
    let anchor: TimeInterval
    let duration: TimeInterval
    init(rotation: APIShopRotation, sent: TimeInterval, received: TimeInterval) {
        anchor = received
        duration = max(0, rotation.endsAt.timeIntervalSince(rotation.serverNow) - max(0, received - sent))
    }
    func remaining(at uptime: TimeInterval) -> TimeInterval { max(0, duration - max(0, uptime - anchor)) }
}

struct APIOwnedItem: Codable, Identifiable, Equatable {
    var id: UUID { ownedItemId }
    let ownedItemId: UUID
    let itemId: String
    let definitionVersion: Int
    let displayName: String
    let description: String
    var flavorDescription: String { ItemDescriptionCopy.concise(description) }
    let rarity: String
    let assetVersion: String
    let modelKey: String
    let thumbnailKey: String
    let clearanceRadius: Decimal
    let placement: APIPlacement?
    var gardenSkills: [APIItemSkill]? = nil

    func rendered() -> GardenItem {
        GardenItem(id: id, itemId: itemId, assetVersion: assetVersion,
                   modelKey: modelKey, thumbnailKey: thumbnailKey,
                   x: placement.map { NSDecimalNumber(decimal: $0.x).doubleValue } ?? 0,
                   y: placement.map { NSDecimalNumber(decimal: $0.y).doubleValue } ?? 0,
                   rotationDegrees: placement.map { NSDecimalNumber(decimal: $0.rotationDegrees).doubleValue } ?? 0)
    }
}

struct APIItemInventory: Codable {
    let items: [APIOwnedItem]
    let nextCursor: UUID?
    let capacity: APIItemCapacity?
}

struct APIItemCapacity: Codable, Equatable {
    let ownedItems: Int
    let placedItems: Int
    let storedItems: Int
    let itemLimit: Int
    var full: Bool { ownedItems >= itemLimit }
    var room: Int { max(0, itemLimit - ownedItems) }
}

struct APIItemShopOffer: Codable, Identifiable {
    let offerId: String
    let offerVersion: Int
    let tokenCost: String
    let itemId: String
    let definitionVersion: Int
    let displayName: String
    let description: String
    var flavorDescription: String { ItemDescriptionCopy.concise(description) }
    let rarity: String
    let assetVersion: String
    let modelKey: String
    let thumbnailKey: String
    var gardenSkills: [APIItemSkill]? = nil
    var startsAt: Date? = nil
    var endsAt: Date? = nil
    var slot: String? = nil
    var remainingAllowance: Int? = nil
    var id: String { "\(offerId)/\(offerVersion)" }
    var appearance: GardenItem {
        GardenItem(id: UUID(), itemId: itemId, assetVersion: assetVersion,
                   modelKey: modelKey, thumbnailKey: thumbnailKey, x: 0, y: 0, rotationDegrees: 0)
    }
}

struct APIItemSaleQuote: Codable {
    let ownedItemId: UUID
    let valuationVersion: String
    let tokenValue: String
    let resaleBasisPoints: Int
    let tokens: String
}

struct ItemSellBody: Codable {
    let requestId: UUID
    let valuationVersion: String
    let expectedTokens: String
}

struct GardenItem: Codable, Identifiable, Equatable {
    let id: UUID
    let itemId: String
    let assetVersion: String
    let modelKey: String
    let thumbnailKey: String
    var x: Double
    var y: Double
    var rotationDegrees: Double
}

struct ItemEditAction: Codable, Equatable {
    let action: String
    let itemId: UUID
    var x: Decimal? = nil
    var y: Decimal? = nil
    var rotationDegrees: Decimal? = nil
}

struct ItemCandidate: Equatable {
    let item: APIOwnedItem
    let action: String
    var x: Decimal
    var y: Decimal
    var rotation: Decimal
    var validity: PlacementValidity = .unavailable
}

struct ItemRenderPreview: Equatable {
    var item: GardenItem
    let radius: Double
    let valid: Bool
    let movable: Bool
}
