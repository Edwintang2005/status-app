import SwiftUI

/// Instagram-style pinch zoom: the picture magnifies around the pinch while
/// the fingers are down and springs back the moment they lift. A *peek*, not
/// a zoom mode — nothing to reset, no state to get stuck in, which is why
/// `@GestureState` carries it: the framework guarantees the snap-back even if
/// the gesture is interrupted by a call or an app switch.
private struct PinchToZoom: ViewModifier {
    private struct Zoom: Equatable {
        var scale: CGFloat = 1
        var anchor: UnitPoint = .center
    }

    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.35)))
    private var zoom = Zoom()

    func body(content: Content) -> some View {
        content
            .scaleEffect(zoom.scale, anchor: zoom.anchor)
            // Above its siblings while zoomed, so the magnified picture rides
            // over neighbouring cards instead of slipping beneath them.
            .zIndex(zoom.scale > 1 ? 1 : 0)
            .gesture(
                MagnifyGesture()
                    .updating($zoom) { value, state, _ in
                        // No shrinking below natural size: pinching in would
                        // just make the picture look broken.
                        state.scale = max(1, value.magnification)
                        state.anchor = value.startAnchor
                    }
            )
    }
}

extension View {
    /// Two-finger magnify-to-peek with automatic spring-back on release.
    /// Two-finger only, so it coexists with taps, buttons and page swipes.
    func pinchToZoom() -> some View {
        modifier(PinchToZoom())
    }
}
