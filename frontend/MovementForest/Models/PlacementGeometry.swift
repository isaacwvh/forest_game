import Foundation

struct PlacementCircle {
    let id: UUID
    let x: Int64
    let y: Int64
    let radius: Int64
}

enum PlacementValidity: Equatable {
    case valid, outOfBounds, overlap, unavailable
    var message: String {
        switch self {
        case .valid: return "Ready to place"
        case .outOfBounds: return "Keep the entire clearance circle inside the garden."
        case .overlap: return "Leave room between the plants’ clearance circles."
        case .unavailable: return "Placement rules are unavailable. Refresh your garden."
        }
    }
}

enum PlacementGeometry {
    static let maximumUnits: Int64 = 999_999_999

    static func units(_ value: Decimal) throws -> Int64 {
        let scaled = value * 1000
        var source = scaled
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard !value.isNaN, value >= 0, scaled <= Decimal(maximumUnits), rounded == scaled else {
            throw ForestError.invalidData("Unsupported placement precision or range.")
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func canonical(_ value: Double, places: Int = 3) -> Decimal? {
        guard value.isFinite, abs(value) <= 999_999.999 else { return nil }
        var source = Decimal(value)
        var result = Decimal()
        NSDecimalRound(&result, &source, places, .plain)
        return result
    }

    static func rotation(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        guard let rounded = canonical(wrapped < 0 ? wrapped + 360 : wrapped, places: 2) else { return nil }
        return rounded == 360 ? 0 : rounded
    }

    static func validate(width: Int64, depth: Int64, circles: [PlacementCircle]) -> PlacementValidity {
        // Bounds keep squared distances and radius sums safely inside Int64.
        guard width > 0, depth > 0, width <= maximumUnits, depth <= maximumUnits,
              circles.allSatisfy({ $0.radius > 0 && $0.radius <= maximumUnits &&
                  $0.x >= 0 && $0.x <= maximumUnits && $0.y >= 0 && $0.y <= maximumUnits }) else { return .outOfBounds }
        for circle in circles {
            guard circle.radius <= circle.x, circle.x <= width - circle.radius,
                  circle.radius <= circle.y, circle.y <= depth - circle.radius else { return .outOfBounds }
        }
        for (index, first) in circles.enumerated() {
            for second in circles.dropFirst(index + 1) {
                let dx = first.x - second.x, dy = first.y - second.y
                let radius = first.radius + second.radius
                if dx * dx + dy * dy < radius * radius { return .overlap }
            }
        }
        return .valid
    }
}
