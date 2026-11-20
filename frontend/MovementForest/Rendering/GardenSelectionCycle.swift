import Foundation

/// Tap-only state. Candidates must be supplied nearest first, from the current tap.
struct GardenSelectionCycle {
    private struct Sequence {
        let origin: CGPoint
        let candidates: [UUID]
        var index: Int
        var time: TimeInterval
    }

    private var sequence: Sequence?
    private let tapTolerance: CGFloat = 24
    private let repeatInterval: TimeInterval = 2

    mutating func reset() { sequence = nil }

    mutating func select(at point: CGPoint, candidates: [UUID], currentSelection: UUID?, time: TimeInterval) -> UUID? {
        // A decoration can contribute several mesh hits, but gets only one turn.
        var seen = Set<UUID>()
        let unique = candidates.filter { seen.insert($0).inserted }
        guard let nearest = unique.first else { reset(); return nil }
        guard unique.count > 1 else { reset(); return nearest }

        if var previous = sequence {
            let dx = point.x - previous.origin.x, dy = point.y - previous.origin.y
            if time >= previous.time, time - previous.time <= repeatInterval,
               dx * dx + dy * dy <= tapTolerance * tapTolerance,
               Set(previous.candidates) == seen,
               currentSelection == previous.candidates[previous.index] {
                // Retain the original order if wind or finger movement changes depth order.
                previous.index = (previous.index + 1) % previous.candidates.count
                previous.time = time
                sequence = previous
                return previous.candidates[previous.index]
            }
        }
        sequence = Sequence(origin: point, candidates: unique, index: 0, time: time)
        return nearest
    }
}
