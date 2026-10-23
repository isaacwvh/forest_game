import SwiftUI

/// Reserve panel space from screen geometry, never from transient status text.
/// Long messages and Dynamic Type scroll inside their panels, leaving the camera
/// projection and the butterfly's flight area unchanged.
@MainActor
struct GardenViewportLayout<Scene: View, Status: View, Controls: View>: View {
    let compact: Bool
    @ViewBuilder let scene: () -> Scene
    @ViewBuilder let status: () -> Status
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            if compact {
                HStack(spacing: 0) {
                    scene().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    ScrollView {
                        status()
                        controls()
                    }
                    .frame(width: min(340, geometry.size.width * 0.42))
                    .background(Color(uiColor: .systemBackground))
                }
            } else {
                VStack(spacing: 0) {
                    ScrollView { status() }
                        .frame(height: min(320, geometry.size.height * 0.42))
                        .background(Color(uiColor: .systemBackground))
                    scene().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    ScrollView { controls() }
                        .frame(height: min(180, geometry.size.height * 0.24))
                        .background(Color(uiColor: .systemBackground))
                }
            }
        }
    }
}
