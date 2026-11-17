// Console validation for the unchanged Foundation evaluator and draft model.
struct StrategyValidationContract: Decodable {
    let cases: [Case]
    struct Case: Decodable {
        let name: String
        let plants: [APIOwnedPlant]
        let items: [APIOwnedItem]
        let context: APIStrategyContext
        let expectedSignature: String
    }
}
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let contract = try JSONDecoder().decode(StrategyValidationContract.self, from: Data(contentsOf: fixtures))
var failed = 0
for example in contract.cases {
    do {
        let actual = try GardenStrategyEvaluator.evaluate(plants: example.plants, items: example.items, context: example.context)
        let reversed = try GardenStrategyEvaluator.evaluate(plants: Array(example.plants.reversed()), items: Array(example.items.reversed()), context: example.context)
        if actual.signature != example.expectedSignature || actual.signature != reversed.signature {
            failed += 1
            print("FAIL: \(example.name)")
            if failed <= 3 {
                print("Expected: " + example.expectedSignature)
                print("Actual: " + actual.signature)
            }
        }
    } catch { failed += 1; print("FAIL: \(example.name): \(error)") }
}
precondition(failed == 0, "\(failed) native calculation cases failed")
print("PASS: \(contract.cases.count) backend/native calculation cases, including reversed input order.")

struct StrategyEditorFixture: Decodable { let emptyGarden: APIGarden; let inventory: APIInventory }
let editorURL = fixtures.deletingLastPathComponent().appendingPathComponent("editor-contract.json")
let editor = try JSONDecoder().decode(StrategyEditorFixture.self, from: Data(contentsOf: editorURL))
var draft = GardenDraftSession(garden: editor.emptyGarden, plants: editor.inventory.plants, items: [])
let plant = editor.inventory.plants[0]
var layout = draft.layout
layout.plants[plant.id] = APIPlacement(gardenId: editor.emptyGarden.gardenId, x: 2, y: 3, rotationDegrees: 45)
draft.apply(layout)
layout.plants[plant.id] = APIPlacement(gardenId: editor.emptyGarden.gardenId, x: 4, y: 5, rotationDegrees: 90)
draft.apply(layout)
precondition(draft.undo.count == 2 && draft.changed)
let batch = draft.request()
precondition(batch.actions.count == 1 && batch.actions[0].action == .plant && batch.actions[0].x == 4)
layout.plants.removeValue(forKey: plant.id)
draft.apply(layout)
precondition(!draft.changed && draft.request().actions.isEmpty)
let roundtrip = try JSONDecoder().decode(GardenDraftSession.self, from: JSONEncoder().encode(draft))
precondition(roundtrip == draft)
print("PASS: draft normalization, net-zero edits and persisted round-trip.")
