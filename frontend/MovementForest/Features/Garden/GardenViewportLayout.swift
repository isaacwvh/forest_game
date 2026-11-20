import SwiftUI

/// Browsing and editing controls overlay the full scene without reserving
/// viewport space. The mounted scene keeps the same structural identity.
@MainActor
struct GardenViewportLayout<Scene: View, Status: View, Controls: View>: View {
    let compact: Bool
    var editing = false
    @Environment(\.gardenBottomNavigationTop) private var navigationTop
    @Environment(\.gardenHomeChrome) private var chrome
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var metricsHeight: CGFloat = 44
    @State private var navigationHeight: CGFloat = 44
    @State private var shortcutsHeight: CGFloat = 240
    @ViewBuilder let scene: () -> Scene
    @ViewBuilder let status: () -> Status
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { outer in
            viewport(insets: chrome.enabled && !editing ? outer.safeAreaInsets : EdgeInsets())
                .ignoresSafeArea(.container, edges: chrome.enabled && !editing ? .all : [])
        }
    }

    private func viewport(insets: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let top = editing && !compact ? min(190, geometry.size.height * 0.3) : 0
            // Bound editing overlays without subtracting space from the scene.
            let bottom = editing && !compact ? max(0, geometry.size.height - top - 44) : 0
            let side = editing && compact ? min(380, geometry.size.width * 0.48) : 0
            let browsingHeight = editing ? geometry.size.height : min(geometry.size.height,
                max(0, (navigationTop ?? (geometry.frame(in: .global).maxY -
                    (chrome.enabled ? insets.bottom + 54 : 0))) - geometry.frame(in: .global).minY))
            scene()
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .overlay(alignment: .top) {
                    if !editing {
                        ViewThatFits(in: .vertical) {
                            browsingStatus(insets: insets)
                            ScrollView { browsingStatus(insets: insets) }
                        }.frame(maxHeight: browsingHeight * 0.55, alignment: .top).clipped()
                            .transformPreference(GardenOverlayFrames.self) { frames in
                                let visible = CGRect(x: 0, y: 0, width: geometry.size.width, height: browsingHeight * 0.55)
                                frames = frames.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
                            }
                    } else if !compact {
                        ViewThatFits(in: .vertical) {
                            status()
                            ScrollView { status() }
                        }.frame(maxHeight: top, alignment: .top).clipped()
                    }
                }
                .overlay(alignment: .topLeading) {
                    if chrome.enabled && !editing {
                        let start = insets.top + navigationHeight + metricsHeight + 8
                        let available = max(0, browsingHeight - start - 8)
                        Group {
                            if shortcutsHeight <= available {
                                measuredShortcuts
                            } else {
                                ScrollView(.vertical) { measuredShortcuts }.scrollIndicators(.hidden)
                                    .frame(height: available).clipped()
                            }
                        }.frame(width: textSize.isAccessibilitySize ? 100 : 60, alignment: .top)
                            .padding(.top, start)
                            .transformPreference(GardenOverlayFrames.self) { frames in
                                let visible = CGRect(x: 0, y: start, width: textSize.isAccessibilitySize ? 100 : 60, height: available)
                                frames = frames.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    if chrome.enabled && !editing { chrome.bottom.padding(.bottom, insets.bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !editing {
                        ViewThatFits(in: .vertical) {
                            controls()
                            ScrollView { controls() }
                        }.frame(maxHeight: browsingHeight * 0.4, alignment: .bottom).clipped()
                            .transformPreference(GardenOverlayFrames.self) { frames in
                                let visible = CGRect(x: 0, y: browsingHeight * 0.6,
                                                     width: geometry.size.width, height: browsingHeight * 0.4)
                                frames = frames.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
                            }
                            .padding(.bottom, geometry.size.height - browsingHeight)
                    } else if !compact {
                        controls().frame(maxHeight: bottom, alignment: .bottom).clipped()
                    }
                }
                .overlay(alignment: .trailing) {
                    if editing && compact {
                        VStack(spacing: 0) {
                            ViewThatFits(in: .vertical) {
                                status()
                                ScrollView { status() }
                            }.frame(maxHeight: geometry.size.height * 0.35, alignment: .top).clipped()
                            Spacer(minLength: 0)
                            controls().frame(maxHeight: geometry.size.height * 0.65, alignment: .bottom).clipped()
                        }.frame(width: side, height: geometry.size.height, alignment: .top).clipped()
                    }
                }
        }.coordinateSpace(name: "garden.viewport")
            .onPreferenceChange(GardenMetricsHeight.self) { metricsHeight = $0 }
            .onPreferenceChange(GardenHomeNavigationHeight.self) { navigationHeight = $0 }
            .onPreferenceChange(GardenHomeShortcutsHeight.self) { shortcutsHeight = $0 }
    }

    private var measuredShortcuts: some View {
        chrome.shortcuts.background(GeometryReader { geometry in
            Color.clear.preference(key: GardenHomeShortcutsHeight.self, value: geometry.size.height)
        })
    }

    private func browsingStatus(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            if chrome.enabled {
                chrome.navigation.background(GeometryReader { geometry in
                    Color.clear.preference(key: GardenHomeNavigationHeight.self, value: geometry.size.height)
                })
            }
            status()
        }.padding(.top, insets.top)
    }
}

private struct GardenHomeNavigationHeight: PreferenceKey {
    static var defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct GardenHomeShortcutsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
