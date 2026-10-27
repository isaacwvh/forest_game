import SwiftUI
import HealthKit

/// Child sheets, confirmations and edits must not compete with the entry sheet.
struct EntryPresentationBlocker: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

enum PlantRarity: String, CaseIterable {
    case common, rare, epic, legendary
    init?(label: String?) {
        guard let value = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        self.init(rawValue: value)
    }
    var title: String { rawValue.capitalized }

    /// Text colours are deliberately separate from the brighter pack-light palette.
    func textRGB(dark: Bool, increasedContrast: Bool = false) -> [Double] {
        let base: [Double]
        switch (self, dark) {
        case (.common, false): base = [0.36, 0.36, 0.36]
        case (.rare, false): base = [0.08, 0.32, 0.70]
        case (.epic, false): base = [0.46, 0.20, 0.66]
        case (.legendary, false): base = [0.48, 0.32, 0.02]
        case (.common, true): base = [0.78, 0.78, 0.78]
        case (.rare, true): base = [0.40, 0.70, 1]
        case (.epic, true): base = [0.80, 0.60, 1]
        case (.legendary, true): base = [1, 0.80, 0.30]
        }
        return increasedContrast ? base.map { dark ? $0 + (1 - $0) * 0.15 : $0 * 0.82 } : base
    }
}

extension APICatalogue {
    func rarity(for speciesID: String) -> String? { species.first { $0.speciesId == speciesID }?.rarity }
}

/// Display metadata for bundled sample/asset views only; approved launch_balance.PLANTS.
/// Connected names always use their actual catalogue, including legacy/unknown values.
enum SamplePlantPresentation {
    static let rarities = ["oak": "common", "moonwillow": "epic"]
}

struct PlantNameText: View {
    let name: String
    let rarity: String?
    var onDarkBackground = false
    var announcesRarity = true
    var suffix = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ name: String, rarity: String?, onDarkBackground: Bool = false, announcesRarity: Bool = true, suffix: String = "") {
        self.name = name; self.rarity = rarity; self.onDarkBackground = onDarkBackground
        self.announcesRarity = announcesRarity; self.suffix = suffix
    }
    private var colour: Color {
        let dark = onDarkBackground || scheme == .dark
        guard let value = PlantRarity(label: rarity) else { return dark ? .white : .primary }
        let rgb = value.textRGB(dark: dark, increasedContrast: contrast == .increased)
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }
    var body: some View {
        (Text(name).foregroundColor(colour) + Text(suffix))
            .accessibilityLabel(name + suffix + (announcesRarity ? PlantRarity(label: rarity).map { ", " + $0.title } ?? "" : ""))
    }
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

struct SkillSummaryLabel: View {
    let skill: APISkillSummary.Effect
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name).font(.headline)
            Text(skill.bonusText).font(.subheadline).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
