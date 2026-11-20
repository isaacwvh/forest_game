import Foundation
#if canImport(MovementForest)
@testable import MovementForest
#endif

/// Shared by hosted XCTest and the portable runner; exercises the shipped policy.
enum GardenSelectionChecks {
    private struct Failure: Error { let reason: String }

    static func run() throws -> Int {
        let oak = UUID(), flower = UUID(), bench = UUID(), other = UUID()
        var cycle = GardenSelectionCycle()
        var selected: UUID?
        var time: TimeInterval = 10
        var count = 0
        func tap(_ hits: [UUID], _ expected: UUID?, _ reason: String,
                 at point: CGPoint = CGPoint(x: 100, y: 100), after delay: TimeInterval = 0.1) throws {
            time += delay
            let actual = cycle.select(at: point, candidates: hits, currentSelection: selected, time: time)
            guard actual == expected else { throw Failure(reason: reason) }
            selected = actual
            count += 1
        }

        try tap([oak], oak, "A distinct tap selects immediately")
        try tap([oak], oak, "Repeated distinct taps never cycle")
        try tap([flower], flower, "A distinct flower tap selects the flower")
        try tap([oak, flower], oak, "The first overlap tap selects nearest, even after a distinct selection")
        try tap([oak, flower], flower, "A second overlap tap reaches the flower")
        try tap([oak, flower], oak, "Cycling wraps to the front")
        try tap([oak, flower], flower, "Cycling continues")
        try tap([oak], oak, "Leaving the intersection immediately selects the only hit")
        try tap([oak, flower], oak, "Reentering the intersection starts at nearest")
        try tap([], nil, "Empty ground clears selection")
        try tap([oak, flower], oak, "Empty ground resets the cycle")

        cycle.reset()
        try tap([oak, oak, flower, flower, bench], oak, "Multiple mesh hits start at the nearest object")
        try tap([oak, flower, bench, oak], flower, "An object gets only one turn")
        try tap([oak, flower, bench], bench, "A third object is reachable")
        try tap([oak, flower, bench], oak, "Three-object cycling wraps")
        try tap([bench, flower, oak], flower, "Depth reorder preserves the established cycle")
        try tap([flower, oak, bench], bench, "Further depth changes do not skip objects")

        cycle.reset()
        try tap([oak, flower], oak, "An explicit reset starts nearest")
        try tap([oak, flower], flower, "Small finger movement is tolerated", at: CGPoint(x: 108, y: 106))
        try tap([oak, flower], oak, "Distant taps start a new sequence", at: CGPoint(x: 180, y: 100))
        try tap([oak, flower], flower, "New location can cycle", at: CGPoint(x: 180, y: 100))
        try tap([oak, flower], oak, "Returning to the original location starts nearest")
        try tap([oak, flower], flower, "Jitter inside the cluster continues", at: CGPoint(x: 120, y: 100))
        try tap([oak, flower], oak, "Cluster stays anchored rather than drifting", at: CGPoint(x: 140, y: 100))
        try tap([oak, flower], flower, "The new cluster can continue", at: CGPoint(x: 140, y: 100))
        try tap([oak, flower], oak, "A pause expires the cycle", at: CGPoint(x: 140, y: 100), after: 2.1)

        cycle.reset()
        try tap([oak, flower], oak, "Reset for changed candidates")
        try tap([oak, flower], flower, "Advance before scene change")
        try tap([oak, bench], oak, "Different overlapping objects restart nearest")
        try tap([oak, bench], bench, "Changed objects can cycle")
        try tap([oak, bench, flower], oak, "An added candidate restarts nearest")
        try tap([oak, bench], oak, "A removed candidate restarts nearest")

        selected = other
        try tap([oak, bench], oak, "Selection from a list interrupts cycling")
        try tap([oak, bench], bench, "Cycling resumes after a fresh first tap")
        selected = nil
        try tap([oak, bench], oak, "Dismissing selection interrupts cycling")
        try tap([oak, bench], bench, "Dismissed sequence can restart")
        cycle.reset()
        try tap([oak, bench], oak, "Camera, layout or lifecycle reset restarts nearest")
        try tap([oak, bench], bench, "Reset sequence advances normally")
        try tap([oak, bench], oak, "A backwards clock restarts nearest", after: -1)
        try tap([flower, flower], flower, "Duplicate hits on one object remain a distinct tap")
        try tap([flower, flower], flower, "Duplicate hits never create an overlap cycle")

        cycle.reset()
        let crowded = (0..<128).map { _ in UUID() }
        for id in crowded {
            try tap(crowded + crowded, id, "Every object in a crowded intersection is reachable once")
        }
        try tap(crowded, crowded[0], "A crowded cycle wraps without stale or duplicate entries")
        return count
    }
}
