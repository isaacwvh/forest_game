import Foundation

struct GardenDraftLayout: Codable, Equatable {
    var plants: [UUID: APIPlacement]
    var items: [UUID: APIPlacement]
    init(_ garden: APIGarden) {
        plants = Dictionary(uniqueKeysWithValues: garden.plants.compactMap { plant in plant.placement.map { (plant.id, $0) } })
        items = Dictionary(uniqueKeysWithValues: (garden.items ?? []).compactMap { item in item.placement.map { (item.id, $0) } })
    }
}

struct GardenDraftSession: Codable, Equatable {
    var baseline: APIGarden
    var layout: GardenDraftLayout
    var plants: [APIOwnedPlant]
    var items: [APIOwnedItem]
    var undo: [GardenDraftLayout] = []
    var redo: [GardenDraftLayout] = []
    init(garden: APIGarden, plants: [APIOwnedPlant], items: [APIOwnedItem]) {
        baseline = garden; layout = GardenDraftLayout(garden)
        self.plants = plants; self.items = items
    }
    var changed: Bool { layout != GardenDraftLayout(baseline) }
    var placedPlants: [APIOwnedPlant] {
        plants.compactMap { value in
            guard let placement = layout.plants[value.id] else { return nil }
            var value = value; value.placement = placement; return value
        }
    }
    var placedItems: [APIOwnedItem] {
        items.compactMap { value in
            guard let placement = layout.items[value.id] else { return nil }
            var value = value; value.placement = placement; return value
        }
    }
    mutating func apply(_ next: GardenDraftLayout) {
        guard layout != next else { return }
        undo.append(layout)
        if undo.count > 100 { undo.removeFirst() }
        redo = []; layout = next
    }
    func request() -> GardenEditRequest {
        let original = GardenDraftLayout(baseline)
        let actions = Set(original.plants.keys).union(layout.plants.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { id -> GardenEditAction? in
            let before = original.plants[id], after = layout.plants[id]
            guard before != after else { return nil }
            guard let after = after else { return GardenEditAction(action: .store, plantId: id) }
            if before == nil { return GardenEditAction(action: .plant, plantId: id, x: after.x, y: after.y, rotationDegrees: after.rotationDegrees) }
            if before?.x == after.x && before?.y == after.y {
                return GardenEditAction(action: .rotate, plantId: id, rotationDegrees: after.rotationDegrees)
            }
            return GardenEditAction(action: .move, plantId: id, x: after.x, y: after.y, rotationDegrees: after.rotationDegrees)
        }
        let itemActions = Set(original.items.keys).union(layout.items.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { id -> ItemEditAction? in
            let before = original.items[id], after = layout.items[id]
            guard before != after else { return nil }
            guard let after = after else { return ItemEditAction(action: "store", itemId: id) }
            if before == nil { return ItemEditAction(action: "place", itemId: id, x: after.x, y: after.y, rotationDegrees: after.rotationDegrees) }
            if before?.x == after.x && before?.y == after.y {
                return ItemEditAction(action: "rotate", itemId: id, rotationDegrees: after.rotationDegrees)
            }
            return ItemEditAction(action: "move", itemId: id, x: after.x, y: after.y, rotationDegrees: after.rotationDegrees)
        }
        return GardenEditRequest(requestId: UUID(), expectedLayoutVersion: baseline.layoutVersion,
            catalogVersion: baseline.catalogVersion, actions: actions, itemActions: itemActions.isEmpty ? nil : itemActions)
    }
}
