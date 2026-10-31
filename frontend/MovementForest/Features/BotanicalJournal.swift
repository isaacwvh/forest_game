import SwiftUI
import UIKit
import ImageIO

/// Presentation only. Gameplay amounts, stages and rarity continue to come from the stores.
enum JournalTheme {
    static let paper = Color(red: 0.969, green: 0.957, blue: 0.914)
    static let sage = Color(red: 0.906, green: 0.929, blue: 0.875)
    static let ink = Color(red: 0.149, green: 0.243, blue: 0.188)
    static let secondary = Color(red: 0.325, green: 0.388, blue: 0.310)
    static let action = Color(red: 0.200, green: 0.373, blue: 0.259)
    static let vine = Color(red: 0.420, green: 0.467, blue: 0.329)

    static func frame(_ rarity: String?) -> Color {
        switch PlantRarity(label: rarity) {
        case .common: return Color(red: 0.455, green: 0.471, blue: 0.439)
        case .rare: return Color(red: 0.208, green: 0.408, blue: 0.671)
        case .epic: return Color(red: 0.506, green: 0.341, blue: 0.639)
        case .legendary: return Color(red: 0.580, green: 0.439, blue: 0.137)
        case nil: return Color(red: 0.478, green: 0.498, blue: 0.475)
        }
    }

    static func raritySymbol(_ rarity: String?) -> String {
        switch PlantRarity(label: rarity) {
        case .common: return "circle.fill"
        case .rare: return "diamond.fill"
        case .epic: return "sparkle"
        case .legendary: return "sun.max.fill"
        case nil: return "questionmark"
        }
    }
}

private enum JournalArtwork {
    static let corners = ["top-left", "top-right", "bottom-left", "bottom-right"]
    static let images: [String: UIImage] = Dictionary(uniqueKeysWithValues:
        (corners.map { "vine-corner-" + $0 } + ["vine-divider"]).compactMap { name in
            PresentationAssets.image("journal/v1/\(name).png", maximumPixels: 240).map { (name, $0) }
        })
}

struct JournalVines: View {
    var size: CGFloat = 70
    var body: some View {
        ZStack {
            corner("top-left", alignment: .topLeading)
            corner("top-right", alignment: .topTrailing)
            corner("bottom-left", alignment: .bottomLeading)
            corner("bottom-right", alignment: .bottomTrailing)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func corner(_ name: String, alignment: Alignment) -> some View {
        Group {
            if let image = JournalArtwork.images["vine-corner-" + name] {
                Image(uiImage: image).resizable().scaledToFit().frame(width: size, height: size)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

struct JournalPageBackground: View {
    var body: some View {
        JournalTheme.paper.overlay(JournalVines().padding(3))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct JournalSectionHeading: View {
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(.title3, design: .serif).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Rectangle().fill(JournalTheme.vine.opacity(0.45)).frame(height: 1).accessibilityHidden(true)
        }.foregroundStyle(JournalTheme.ink).padding(.top, 8).padding(.bottom, 4)
    }
}

struct JournalGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    var minimumWidth: CGFloat = 104
    var fixedColumns: Int? = nil
    let content: Content
    init(minimumWidth: CGFloat = 104, fixedColumns: Int? = nil, @ViewBuilder content: () -> Content) {
        self.minimumWidth = minimumWidth; self.fixedColumns = fixedColumns; self.content = content()
    }
    private var columns: [GridItem] {
        if textSize.isAccessibilitySize { return [GridItem(.flexible())] }
        if let count = fixedColumns, textSize < .xxxLarge {
            return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
        }
        let minimum = textSize >= .xxxLarge ? max(154, minimumWidth) : minimumWidth
        return [GridItem(.adaptive(minimum: minimum, maximum: 220), spacing: 10, alignment: .top)]
    }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) { content }
    }
}

struct JournalSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Find a plant", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .accessibilityLabel("Find a plant")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                }.accessibilityLabel("Clear search")
            }
        }.foregroundStyle(JournalTheme.secondary)
            .padding(.leading, 14).padding(.trailing, text.isEmpty ? 14 : 0)
            .frame(minHeight: 48).background(JournalTheme.sage.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Metrics are standalone controls, never nested inside a plant's navigation button.
/// Tap and hold both explain; neither performs a game operation.
struct JournalInfoIcon: View {
    let title: String
    let explanation: String
    var metric: String? = nil
    var symbol: String = "info.circle"
    var color: Color = JournalTheme.action
    @State private var explaining = false
    var body: some View {
        Button { explaining = true } label: {
            Group {
                if let metric = metric { QuantityIcon(metric: metric) }
                else { Image(systemName: symbol).font(.body).foregroundStyle(color) }
            }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityHint("Show explanation")
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in explaining = true })
        .popover(isPresented: $explaining) {
            JournalExplanation(title: title, explanation: explanation, close: { explaining = false })
        }
    }
}

private struct JournalExplanation: View {
    let title: String
    let explanation: String
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ViewBuilder var body: some View {
        if #available(iOS 16.4, *) {
            fittedContent.presentationCompactAdaptation(.popover)
        } else { fittedContent }
    }
    @ViewBuilder private var fittedContent: some View {
        if textSize.isAccessibilitySize {
            ScrollView { content }.frame(width: 280, height: 360)
                .background(JournalTheme.paper).accessibilityAction(.escape, close)
        } else { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close explanation")
            }
            if !explanation.isEmpty {
                Text(explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(width: 250)
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
            .background(JournalTheme.paper).accessibilityAction(.escape, close)
    }
}

struct JournalMetric: View {
    let title: String
    let value: String
    let explanation: String
    var metric: String? = nil
    var symbol: String = "info.circle"
    var compact = false
    var body: some View {
        HStack(spacing: 0) {
            JournalInfoIcon(title: title, explanation: explanation, metric: metric, symbol: symbol)
            Text(value).font(compact ? .caption2 : .callout).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(title), \(value)")
        }.foregroundStyle(JournalTheme.ink)
    }
}

struct JournalRarity: View {
    let rarity: String?
    var body: some View {
        JournalInfoIcon(title: PlantRarity(label: rarity)?.title ?? "Rarity unavailable",
                        explanation: "",
                        symbol: JournalTheme.raritySymbol(rarity), color: JournalTheme.frame(rarity))
    }
}

struct JournalPlantFrame<Content: View>: View {
    let rarity: String?
    let content: Content
    init(rarity: String?, @ViewBuilder content: () -> Content) {
        self.rarity = rarity; self.content = content()
    }
    var body: some View {
        content.frame(maxWidth: .infinity)
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(JournalTheme.frame(rarity), style: StrokeStyle(lineWidth: 1.8,
                        dash: PlantRarity(label: rarity) == nil ? [4, 3] : []))
                    .allowsHitTesting(false)
            }
            .overlay(JournalVines(size: 30).padding(3))
    }
}

/// Display-sized shared PNGs. Catalog masking is chosen before rendering;
/// owned art never reads discovery state.
struct JournalPlantImage: View {
    let plant: GardenPlant
    let catalog: any AssetCatalogProviding
    var revealed = true
    var maximumPixels = 360
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 64
        return cache
    }()
    private var image: UIImage? {
        guard let asset = try? catalog.resolve(plant) else { return nil }
        let key = "\(asset.thumbnailURL.path)#\(maximumPixels)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(asset.thumbnailURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        Self.cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).renderingMode(revealed ? .original : .template)
                    .resizable().scaledToFit().foregroundStyle(JournalTheme.secondary)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "leaf").font(.title2)
                    Text("Image unavailable").font(.caption2).multilineTextAlignment(.center)
                }.foregroundStyle(JournalTheme.secondary)
            }
        }.accessibilityHidden(true)
    }
}

struct JournalAttribute: View {
    let title: String
    let value: String
    let explanation: String
    var metric: String? = nil
    var symbol: String = "info.circle"
    var body: some View {
        VStack(spacing: 0) {
            JournalInfoIcon(title: title, explanation: explanation, metric: metric, symbol: symbol)
            if !value.isEmpty {
                Text(value).font(.caption).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                    .accessibilityLabel("\(title), \(value)")
            }
        }.frame(maxWidth: .infinity, alignment: .top).foregroundStyle(JournalTheme.ink)
    }
}

/// Rounds presentation only; stored amounts and growth calculations stay exact.
enum JournalAmount {
    static func water(_ value: String, locale: Locale = .current) -> String {
        guard let amount = ExactAmount.integer(value) else { return "Unavailable" }
        var water = amount / 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &water, 1, .plain)
        if amount > 0 && rounded == 0 {
            return "<" + (Decimal(1) / 10).formatted(.number.locale(locale))
        }
        return rounded.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }
}

/// Reuses the existing exact amount/progress contract; does not award or alter growth.
struct JournalGrowthSummary: Equatable {
    let fraction: Double?
    let remaining: String?
    let displayRemaining: String?
    let nextStage: String?
    let fullyGrown: Bool
    init(plant: APIOwnedPlant) {
        let progress = plant.growthProgress
        let resolvedFraction = progress?.fraction(growth: plant.growthMicroUnits)
        fraction = resolvedFraction
        fullyGrown = plant.growthStage == .adult
        if let next = progress?.nextStageMicroUnits,
           let target = ExactAmount.integer(next), let current = ExactAmount.integer(plant.growthMicroUnits),
           resolvedFraction != nil {
            let rawRemaining = NSDecimalNumber(decimal: max(0, target - current)).stringValue
            remaining = ExactAmount.water(rawRemaining)
            displayRemaining = JournalAmount.water(rawRemaining)
            nextStage = plant.growthStage.next.map { $0 == .young ? "Young" : $0.title }
        } else { remaining = nil; displayRemaining = nil; nextStage = nil }
    }
    var caption: String {
        if fullyGrown { return "Fully grown" }
        if let remaining = displayRemaining, let nextStage = nextStage { return "\(remaining) to \(nextStage)" }
        return "Growth unavailable"
    }
}

struct JournalPlantProgress: View {
    let plant: APIOwnedPlant
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 44
    private var summary: JournalGrowthSummary { JournalGrowthSummary(plant: plant) }
    var body: some View {
        VStack(spacing: 2) {
            Group {
                if !summary.fullyGrown, let fraction = summary.fraction {
                    ProgressView(value: fraction).tint(JournalTheme.action.opacity(0.75))
                        .accessibilityLabel("Progress to next stage").accessibilityValue(fraction.formatted(.percent))
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }.frame(height: 4)
            Group {
                if summary.fullyGrown {
                    Label("Fully grown", systemImage: "leaf.fill").font(.caption)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(JournalTheme.secondary)
                } else {
                    HStack(spacing: 0) {
                        JournalInfoIcon(title: "Growth", explanation: summary.caption, metric: "water")
                        VStack(alignment: .leading, spacing: 2) {
                            if let remaining = summary.displayRemaining, let nextStage = summary.nextStage {
                                Text(remaining).monospacedDigit()
                                Text("to \(nextStage)")
                            } else {
                                Text("Growth unavailable").lineLimit(2)
                            }
                        }.font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity).frame(height: max(44, rowHeight))
        }.foregroundStyle(JournalTheme.ink)
    }
}

struct PlantInspection: Identifiable { let id: UUID }

/// Catalog-only fallback for an older/offline catalogue's blank or placeholder copy.
/// Authored server descriptions remain authoritative; owned inspection never uses this.
enum CatalogSpeciesCopy {
    private static let bundled: [String: String] = {
        guard let url = PresentationAssets.url("journal/v1/catalog-descriptions.json"),
              let data = try? Data(contentsOf: url),
              let copy = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return copy
    }()
    static func description(for species: APISpecies) -> String? {
        let value = species.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = value, !value.isEmpty, value != "Movement Forest initial collection." { return value }
        return bundled[species.speciesId]
    }
}

/// A real modal keeps background navigation inert while preserving its mounted scene.
struct JournalInspector<Content: View, Footer: View>: View {
    let title: String
    let close: () -> Void
    let content: Content
    let footer: Footer
    @AccessibilityFocusState private var titleFocused: Bool
    init(title: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title; self.close = close; self.content = content(); self.footer = footer()
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea().onTapGesture(perform: close).accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.system(.title2, design: .serif).weight(.semibold))
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    Spacer(minLength: 8)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.title3).frame(width: 44, height: 44)
                            .background(JournalTheme.sage, in: Circle())
                    }.accessibilityLabel("Close plant details").accessibilityIdentifier("plantDetails.close")
                }.padding(.leading, 24).padding(.trailing, 14).padding(.vertical, 10)
                ScrollView {
                    VStack(spacing: 18) { content }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
                }.accessibilityIdentifier("plantDetails.content")
                footer
            }
            .frame(maxWidth: 520, maxHeight: .infinity)
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 24))
            .overlay(JournalVines(size: 64).padding(4))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
        .accessibilityAction(.escape, close)
        .task { titleFocused = true }
    }
}

private struct JournalPresentationBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.4, *) { content.presentationBackground(.clear) }
        else { content.background(ClearJournalPresentation()) }
    }
}

/// iOS 16.0–16.3 fallback; only clears the presentation's own UIKit backing.
private struct ClearJournalPresentation: UIViewRepresentable {
    private final class Backing: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.superview?.superview?.backgroundColor = .clear
            }
        }
    }
    func makeUIView(context: Context) -> UIView {
        let view = Backing(); view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    func journalModalBackground() -> some View { modifier(JournalPresentationBackground()) }
}
