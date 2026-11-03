import SwiftUI

/// Presentation geometry depends on the mode, available safe area and text
/// size, never on selection or message content.
struct GardenViewportRegions {
    let scene: CGRect
    let status: CGRect
    let controls: CGRect
    let usesSidePanel: Bool
    init(size: CGSize, visibleHeight: CGFloat, editing: Bool, compact: Bool, accessibility: Bool) {
        let width = max(0, size.width), height = max(0, min(size.height, visibleHeight))
        usesSidePanel = editing && compact
        if usesSidePanel {
            let side = min(340, width * 0.42)
            scene = CGRect(x: 0, y: 0, width: width - side, height: height)
            status = CGRect(x: width - side, y: 0, width: side, height: 0)
            controls = CGRect(x: width - side, y: 0, width: side, height: height)
        } else {
            let top = min(height * 0.22, accessibility ? 180 : editing ? 96 : 120)
            let bottom = min(height * 0.36, accessibility ? 260 : editing ? 208 : 152)
            status = CGRect(x: 0, y: 0, width: width, height: top)
            scene = CGRect(x: 0, y: top, width: width, height: height - top - bottom)
            controls = CGRect(x: 0, y: height - bottom, width: width, height: bottom)
        }
    }
}

/// The scene always has the same structural identity. Header and selection/
/// editing panels have their own clipped regions outside the visible garden.
@MainActor
struct GardenViewportLayout<Scene: View, Status: View, Controls: View>: View {
    let compact: Bool
    var editing = false
    @Environment(\.gardenBottomNavigationTop) private var navigationTop
    @Environment(\.dynamicTypeSize) private var textSize
    @ViewBuilder let scene: () -> Scene
    @ViewBuilder let status: () -> Status
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            let visibleHeight = editing ? geometry.size.height : min(geometry.size.height,
                max(0, (navigationTop ?? geometry.frame(in: .global).maxY) - geometry.frame(in: .global).minY))
            let regions = GardenViewportRegions(size: geometry.size, visibleHeight: visibleHeight,
                editing: editing, compact: compact, accessibility: textSize.isAccessibilitySize)
            ZStack(alignment: .topLeading) {
                JournalTheme.paper.frame(width: geometry.size.width, height: geometry.size.height)
                scene().frame(width: regions.scene.width, height: regions.scene.height).clipped()
                    .offset(x: regions.scene.minX, y: regions.scene.minY)
                if !regions.usesSidePanel {
                    ScrollView { status() }
                        .frame(width: regions.status.width, height: regions.status.height, alignment: .top)
                        .background(JournalTheme.paper).clipped()
                        .offset(x: regions.status.minX, y: regions.status.minY)
                        .transformPreference(GardenOverlayFrames.self) { frames in
                            frames = frames.map { $0.intersection(regions.status) }.filter { !$0.isNull && !$0.isEmpty }
                        }
                }
                ScrollView {
                    if regions.usesSidePanel { status() }
                    controls()
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(width: regions.controls.width, height: regions.controls.height, alignment: .top)
                .background(JournalTheme.paper).clipped()
                .offset(x: regions.controls.minX, y: regions.controls.minY)
                .transformPreference(GardenOverlayFrames.self) { frames in
                    frames = frames.map { $0.intersection(regions.controls) }.filter { !$0.isNull && !$0.isEmpty }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .transformPreference(GardenOverlayFrames.self) { frames in
                // Convert viewport-space hit exclusions to the scene's local space.
                frames = frames.compactMap { frame in
                    let visible = frame.intersection(regions.scene)
                    return visible.isNull || visible.isEmpty ? nil :
                        visible.offsetBy(dx: -regions.scene.minX, dy: -regions.scene.minY)
                }
            }
        }.coordinateSpace(name: "garden.viewport")
    }
}

/// The custom navigation bar can overlap a NavigationStack's scene bounds.
/// Pass its real top edge through so browsing panels avoid that overlap.
struct GardenBottomNavigationTop: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

private enum GardenBottomNavigationTopKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var gardenBottomNavigationTop: CGFloat? {
        get { self[GardenBottomNavigationTopKey.self] }
        set { self[GardenBottomNavigationTopKey.self] = newValue }
    }
}

/// Only actual overlay content is excluded from native visitor accessibility.
struct GardenOverlayFrames: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func gardenOverlayTarget() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: GardenOverlayFrames.self,
                value: [geometry.frame(in: .named("garden.viewport"))])
        })
    }
}

struct GardenOutline: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .foregroundStyle(enabled ? JournalTheme.ink : JournalTheme.secondary).tint(JournalTheme.action)
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                enabled ? JournalTheme.action : JournalTheme.secondary, lineWidth: contrast == .increased ? 2 : 1))
    }
}

struct GardenOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .modifier(GardenOutline()).opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}
