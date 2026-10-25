import SwiftUI

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
