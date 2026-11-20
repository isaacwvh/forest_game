import SwiftUI

/// Home chrome is injected into the existing viewport, never around a new scene.
struct GardenHomeChrome {
    var enabled = false
    var navigation = AnyView(EmptyView())
    var shortcuts = AnyView(EmptyView())
    var bottom = AnyView(EmptyView())
}

private struct GardenHomeChromeKey: EnvironmentKey {
    static let defaultValue = GardenHomeChrome()
}

extension EnvironmentValues {
    var gardenHomeChrome: GardenHomeChrome {
        get { self[GardenHomeChromeKey.self] }
        set { self[GardenHomeChromeKey.self] = newValue }
    }
}

struct GardenMetricsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct HomeQuantityIcon: View {
    let metric: String
    @ScaledMetric(relativeTo: .caption2) private var size = 20.0
    var body: some View {
        Group {
            if let image = QuantityArtwork.images[metric] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: QuantityArtwork.symbol(metric)).resizable().scaledToFit()
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Material belongs to each control; transparent gaps remain part of the garden.
struct HomeFloatingSurface: ViewModifier {
    var selected = false
    var enabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            if enabled {
            RoundedRectangle(cornerRadius: 11)
                .fill(reduceTransparency ? AnyShapeStyle(selected ? JournalTheme.sage : JournalTheme.paper) :
                    AnyShapeStyle(.thinMaterial))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .fill((selected ? JournalTheme.sage : JournalTheme.paper).opacity(reduceTransparency ? 0 : 0.28))
                }
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 11).strokeBorder(JournalTheme.action, lineWidth: 2)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

extension View {
    func homeFloatingSurface(selected: Bool = false, enabled: Bool = true) -> some View {
        modifier(HomeFloatingSurface(selected: selected, enabled: enabled))
    }
}

struct HomeAttentionBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .symbolRenderingMode(.palette).foregroundStyle(.white, JournalTheme.danger)
            .font(.system(size: 13, weight: .bold))
            .background(Circle().fill(JournalTheme.paper).padding(-1))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

enum HomeNavigationArtwork {
    static let keys = ["shop", "catalog", "packs", "milestones", "expedition"]
    static let images = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
        PresentationAssets.image("home-navigation/v1/\(key).png", maximumPixels: 128).map { (key, $0) }
    })
}

struct HomeCollectionShortcut: View {
    let destination: CollectionDestination
    let attention: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption2) private var iconSize = 36.0

    var body: some View {
        Button(action: action) {
            VStack(spacing: -4) {
                Group {
                    if let image = HomeNavigationArtwork.images[destination.rawValue.lowercased()] {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: destination.symbol).resizable().scaledToFit().padding(5)
                    }
                }.frame(width: iconSize, height: iconSize).accessibilityHidden(true)
                Text(destination.rawValue).font(.caption2.weight(.bold))
                    .foregroundStyle(JournalTheme.paper)
                    .shadow(color: JournalTheme.ink, radius: 1, x: 1, y: 0)
                    .shadow(color: JournalTheme.ink, radius: 1, x: -1, y: 0)
                    .shadow(color: JournalTheme.ink, radius: 1, x: 0, y: 1)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(width: textSize.isAccessibilitySize ? 100 : 60).frame(minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if !attention.isEmpty { HomeAttentionBadge().padding(.trailing, 5) }
                }
        }.buttonStyle(.plain).foregroundStyle(JournalTheme.action)
            .accessibilityLabel(destination.rawValue).accessibilityValue(attention)
            .accessibilityIdentifier("home.shortcut." + destination.id)
            .gardenOverlayTarget()
    }
}
