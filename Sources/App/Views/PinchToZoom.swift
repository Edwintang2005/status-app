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
            // zIndex only orders siblings: a container further out reads this to rise too.
            .preference(key: PinchZoomActiveKey.self, value: zoom.scale > 1)
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

/// Whether a `pinchToZoom` view inside is magnified right now.
struct PinchZoomActiveKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Lifts the view above its siblings while a pinch inside it is magnified. A
/// zIndex driven by the gesture's own state never reordered the stack; this
/// one is ordinary view state, so it does.
private struct RaisedWhilePinched: ViewModifier {
    @State private var pinched = false

    func body(content: Content) -> some View {
        content
            // Through the binding: some SDKs make this closure `@Sendable`.
            .onPreferenceChange(PinchZoomActiveKey.self) { [pinched = $pinched] in pinched.wrappedValue = $0 }
            .zIndex(pinched ? 1 : 0)
    }
}

extension View {
    /// Draws this view over its later siblings (a caption, a button) while a
    /// `pinchToZoom` inside it is magnified.
    func raisedWhilePinched() -> some View {
        modifier(RaisedWhilePinched())
    }

    /// Two-finger magnify-to-peek with automatic spring-back on release.
    /// Two-finger only, so it coexists with taps, buttons and page swipes.
    func pinchToZoom() -> some View {
        modifier(PinchToZoom())
    }
}
