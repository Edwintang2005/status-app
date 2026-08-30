import SwiftUI

/// Pinch-to-peek: magnifies while fingers are down, springs back on lift.
/// `@GestureState` guarantees the snap-back even if the gesture is interrupted.
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
            // Above its siblings while zoomed, so it rides over neighbouring cards.
            .zIndex(zoom.scale > 1 ? 1 : 0)
            .gesture(
                MagnifyGesture()
                    .updating($zoom) { value, state, _ in
                        // No shrinking below natural size.
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
