import Foundation

struct APIOwnedItem: Codable, Identifiable, Equatable {
    var id: UUID { ownedItemId }
    let ownedItemId: UUID
    let itemId: String
    let definitionVersion: Int
    let displayName: String
    let description: String
    let rarity: String
    let assetVersion: String
    let modelKey: String
    let thumbnailKey: String
    let clearanceRadius: Decimal
    let placement: APIPlacement?

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
