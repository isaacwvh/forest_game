import SwiftUI

/// Browsing overlays never participate in scene sizing. Editing retains its
/// geometry-reserved panels, with the scene at the same structural identity.
@MainActor
struct GardenViewportLayout<Scene: View, Status: View, Controls: View>: View {
    let compact: Bool
    var editing = false
    @ViewBuilder let scene: () -> Scene
    @ViewBuilder let status: () -> Status
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            let top = editing && !compact ? min(260, geometry.size.height * 0.32) : 0
            let bottom = editing && !compact ? min(180, geometry.size.height * 0.24) : 0
            let side = editing && compact ? min(340, geometry.size.width * 0.42) : 0
            scene()
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .padding(.top, top).padding(.bottom, bottom).padding(.trailing, side)
                .overlay(alignment: .top) {
                    if !editing {
                        ViewThatFits(in: .vertical) {
                            status()
                            ScrollView { status() }
                        }.frame(maxHeight: geometry.size.height * 0.55, alignment: .top).clipped()
                            .transformPreference(GardenOverlayFrames.self) { frames in
                                let visible = CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height * 0.55)
                                frames = frames.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
                            }
                    } else if !compact {
                        ScrollView { status() }.frame(height: top)
                            .background(Color(uiColor: .systemBackground))
                    }
                }
                .overlay(alignment: .bottom) {
                    if !editing {
                        ViewThatFits(in: .vertical) {
                            controls()
                            ScrollView { controls() }
                        }.frame(maxHeight: geometry.size.height * 0.4, alignment: .bottom).clipped()
                            .transformPreference(GardenOverlayFrames.self) { frames in
                                let visible = CGRect(x: 0, y: geometry.size.height * 0.6,
                                                     width: geometry.size.width, height: geometry.size.height * 0.4)
                                frames = frames.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
                            }
                    } else if !compact {
                        ScrollView { controls() }.frame(height: bottom)
                            .background(Color(uiColor: .systemBackground))
                    }
                }
                .overlay(alignment: .trailing) {
                    if editing && compact {
                        ScrollView { status(); controls() }.frame(width: side)
                            .background(Color(uiColor: .systemBackground))
                    }
                }
        }.coordinateSpace(name: "garden.viewport")
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(reduceTransparency || contrast == .increased ? Color(uiColor: .systemBackground) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(enabled ? Color.forestTint : Color.secondary, lineWidth: 1))
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

struct GardenSelectionPopup: View {
    let name: String
    let variant: String
    let stage: String
    let close: () -> Void
    let details: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(name) · \(variant)").font(.headline).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close plant selection").accessibilityIdentifier("garden.selection.close")
            }
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) :
                AnyLayout(HStackLayout(spacing: 12))
            layout {
                Text(stage).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button("Plant details", action: details).frame(minHeight: 44)
                    .accessibilityIdentifier("garden.details")
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.bottom, 4)
        .frame(maxWidth: 460).modifier(GardenOutline())
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { /* Popup background taps must not select the ground behind it. */ }
        .accessibilityElement(children: .contain).accessibilityIdentifier("garden.selection")
        .gardenOverlayTarget().padding(.horizontal, 12).padding(.vertical, 8)
    }
}
