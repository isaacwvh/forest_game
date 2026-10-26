import SwiftUI
import HealthKit

/// Child sheets, confirmations and edits must not compete with the entry sheet.
struct EntryPresentationBlocker: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

enum OwnedCopyLabel {
    static func title(_ id: UUID, in plants: [APIOwnedPlant]) -> String {
        guard let plant = plants.first(where: { $0.id == id }) else { return "Plant progress" }
        let copies = plants.filter { $0.speciesId == plant.speciesId && $0.variantId == plant.variantId }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let suffix = copies.count > 1 ? " · Copy \((copies.firstIndex { $0.id == id } ?? 0) + 1)" : ""
        return "\(plant.speciesId.capitalized) · \(plant.variantId.capitalized)" + suffix
    }
}

enum ActivityMetricLabel {
    static func title(_ key: String) -> String {
        switch key {
        case "steps": return "Steps"
        case "walking_running_distance_km": return "Walking and running distance"
        case "active_energy_kcal": return "Active energy"
        case "flights_climbed": return "Flights climbed"
        case "workout_minutes.*": return "Recorded workouts (default)"
        default:
            return key.replacingOccurrences(of: "workout_minutes.", with: "Workout: ")
                .replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum QuantityArtwork {
    static let keys = ["steps", "walking_running_distance_km", "active_energy_kcal", "flights_climbed",
                       "workout_minutes.running", "workout_minutes.cycling", "workout_minutes.swimming",
                       "workout_minutes.strength_training", "water", "attraction", "active_visitor_rate",
                       "offline_visitor_rate", "offline_capacity", "tokens"]
    static func path(_ key: String) -> String? {
        keys.contains(key) ? "png-128/\(key).png" : nil
    }
    static func workoutKey(_ type: UInt) -> String {
        switch HKWorkoutActivityType(rawValue: type) {
        case .running?: return "workout_minutes.running"
        case .cycling?: return "workout_minutes.cycling"
        case .swimming?: return "workout_minutes.swimming"
        case .traditionalStrengthTraining?, .functionalStrengthTraining?: return "workout_minutes.strength_training"
        case .walking?: return "workout_minutes.walking"
        case .hiking?: return "workout_minutes.hiking"
        case .yoga?: return "workout_minutes.yoga"
        default: return "workout_minutes.unknown"
        }
    }
    static func symbol(_ key: String) -> String {
        switch key {
        case "workout_minutes.walking": return "figure.walk"
        case "workout_minutes.hiking": return "figure.hiking"
        case "workout_minutes.yoga": return "figure.yoga"
        default: return key.hasPrefix("workout_minutes.") ? "figure.mixed.cardio" : "chart.bar"
        }
    }
    // Decode small runtime exports once; original generation canvases are never bundled.
    static let images: [String: UIImage] = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
        guard let path = path(key), let image = PresentationAssets.image(path, maximumPixels: 128) else { return nil }
        return (key, image)
    })
}

struct QuantityIcon: View {
    let metric: String
    @ScaledMetric(relativeTo: .body) private var size = 24.0
    var body: some View {
        Group {
            if let image = QuantityArtwork.images[metric] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: QuantityArtwork.symbol(metric))
                    .resizable().scaledToFit().padding(3).foregroundStyle(Color.forestTint)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct QuantityLabel: View {
    let metric: String
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { QuantityIcon(metric: metric) }
            .accessibilityElement(children: .combine)
    }
}

struct QuantityDetailRow: View {
    let metric: String
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            QuantityIcon(metric: metric)
            DetailRow(title: title, value: value)
        }.accessibilityElement(children: .combine)
    }
}

struct RecoveryView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf").font(.largeTitle).foregroundStyle(Color.forestTint)
            Text(title).font(.title2).bold()
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlantThumbnail: View {
    let plant: GardenPlant
    let catalog: any AssetCatalogProviding
    var body: some View {
        Group {
            if let asset = try? catalog.resolve(plant), let image = UIImage(contentsOfFile: asset.thumbnailURL.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "leaf").resizable().scaledToFit().padding()
            }
        }.accessibilityHidden(true)
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }.padding(.vertical, 3).accessibilityElement(children: .combine)
    }
}
