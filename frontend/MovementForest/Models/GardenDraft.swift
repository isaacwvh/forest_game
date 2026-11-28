import Foundation

struct GardenDraftLayout: Codable, Equatable {
    var plants: [UUID: APIPlacement]
    var items: [UUID: APIPlacement]
    init(_ garden: APIGarden) {
        plants = Dictionary(uniqueKeysWithValues: garden.plants.compactMap { plant in plant.placement.map { (plant.id, $0) } })
        items = Dictionary(uniqueKeysWithValues: (garden.items ?? []).compactMap { item in item.placement.map { (item.id, $0) } })
    }
}

struct GardenDraftChange: Codable, Equatable {
    struct PlacementChange: Codable, Equatable {
        let id: UUID
        let placement: APIPlacement?
    }

    let plants: [PlacementChange]
    let items: [PlacementChange]

    private init(plants: [PlacementChange], items: [PlacementChange]) {
        self.plants = plants
        self.items = items
    }

    init(from current: GardenDraftLayout, to target: GardenDraftLayout) {
        func changed(_ current: [UUID: APIPlacement], _ target: [UUID: APIPlacement]) -> [PlacementChange] {
            Set(current.keys).union(target.keys).sorted { $0.uuidString < $1.uuidString }.compactMap { id in
                guard current[id] != target[id] else { return nil }
                return PlacementChange(id: id, placement: target[id])
            }
        }
        plants = changed(current.plants, target.plants)
        items = changed(current.items, target.items)
    }

    func applying(to layout: GardenDraftLayout) -> GardenDraftLayout {
        var next = layout
        for change in plants { next.plants[change.id] = change.placement }
        for change in items { next.items[change.id] = change.placement }
        return next
    }

    func removing(plantID: UUID?, itemID: UUID?) -> GardenDraftChange? {
        let remainingPlants = plants.filter { $0.id != plantID }
        let remainingItems = items.filter { $0.id != itemID }
        guard !remainingPlants.isEmpty || !remainingItems.isEmpty else { return nil }
        return GardenDraftChange(plants: remainingPlants, items: remainingItems)
    }
}

struct GardenDraftSession: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case baseline, layout, plants, items, undoChanges, redoChanges, undo, redo
    }
    var baseline: APIGarden
    var layout: GardenDraftLayout
    var plants: [APIOwnedPlant]
    var items: [APIOwnedItem]
    private(set) var undo: [GardenDraftChange] = []
    private(set) var redo: [GardenDraftChange] = []

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try values.decode(APIGarden.self, forKey: .baseline)
        layout = try values.decode(GardenDraftLayout.self, forKey: .layout)
        plants = try values.decode([APIOwnedPlant].self, forKey: .plants)
        items = try values.decode([APIOwnedItem].self, forKey: .items)
        func changes(_ key: CodingKeys, legacy: CodingKeys, layout: GardenDraftLayout) throws -> [GardenDraftChange] {
            if let compact = try values.decodeIfPresent([GardenDraftChange].self, forKey: key) { return compact }
            let snapshots = try values.decodeIfPresent([GardenDraftLayout].self, forKey: legacy) ?? []
            var previous = layout
            var result: [GardenDraftChange] = []
            for target in snapshots.reversed() {
                result.append(GardenDraftChange(from: previous, to: target))
                previous = target
            }
            return result.reversed()
        }
        undo = try changes(.undoChanges, legacy: .undo, layout: layout)
        redo = try changes(.redoChanges, legacy: .redo, layout: layout)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseline, forKey: .baseline)
        try values.encode(layout, forKey: .layout)
        try values.encode(plants, forKey: .plants)
        try values.encode(items, forKey: .items)
        try values.encode(undo, forKey: .undoChanges)
        try values.encode(redo, forKey: .redoChanges)
    }
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
        undo.append(GardenDraftChange(from: next, to: layout))
        if undo.count > 100 { undo.removeFirst() }
        redo = []; layout = next
    }
    mutating func undoLastChange() {
        guard let change = undo.popLast() else { return }
        let previous = change.applying(to: layout)
        redo.append(GardenDraftChange(from: previous, to: layout))
        layout = previous
    }
    mutating func redoLastChange() {
        guard let change = redo.popLast() else { return }
        let next = change.applying(to: layout)
        undo.append(GardenDraftChange(from: next, to: layout))
        layout = next
    }

    mutating func removeSoldCopy(plantID: UUID?, itemID: UUID?) {
        if let id = plantID {
            plants.removeAll { $0.id == id }
            layout.plants.removeValue(forKey: id)
        }
        if let id = itemID {
            items.removeAll { $0.id == id }
            layout.items.removeValue(forKey: id)
        }
        undo = undo.compactMap { $0.removing(plantID: plantID, itemID: itemID) }
        redo = redo.compactMap { $0.removing(plantID: plantID, itemID: itemID) }
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
