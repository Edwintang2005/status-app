import SwiftUI

extension View {
    /// What a zoom transition grows from (iOS 18), clipped to its own corners
    /// so the zoom starts and ends with them; nothing on iOS 17.
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat) -> some View {
        if #available(iOS 18, *) {
            matchedTransitionSource(id: id, in: namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self
        }
    }

    /// A presentation that zooms out of its `zoomSource` (iOS 18). Off, or on
    /// iOS 17, it keeps its own: a sheet slides, a cover rises. `enabled` must
    /// hold for the whole presentation: a change swaps branches and rebuilds it.
    @ViewBuilder
    func zoomsFrom(_ id: some Hashable, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if #available(iOS 18, *), enabled {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }

    /// A moment landing while Home is in front: the card glows like the status
    /// card and settles into place. Outside the card's `.id`, so the glow
    /// survives the card being swapped for the new moment's.
    func momentArrival(_ arrivals: Int) -> some View {
        modifier(MomentArrival(arrivals: arrivals))
    }
}

private struct MomentArrival: ViewModifier {
    let arrivals: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Settle {
        var lift = 0.0
        var scale = 1.0
    }

    func body(content: Content) -> some View {
        let still = reduceMotion
        return content
            .keyframeAnimator(initialValue: Settle(), trigger: arrivals) { card, value in
                card.offset(y: still ? 0 : value.lift)
                    .scaleEffect(still ? 1 : value.scale)
            } keyframes: { _ in
                KeyframeTrack(\.lift) {
                    MoveKeyframe(14)
                    SpringKeyframe(0, duration: 0.6, spring: .bouncy(duration: 0.5, extraBounce: 0.08))
                }
                KeyframeTrack(\.scale) {
                    MoveKeyframe(0.97)
                    SpringKeyframe(1, duration: 0.6, spring: .bouncy(duration: 0.5, extraBounce: 0.08))
                }
            }
            .overlay {
                // The status card's glow, so all three arrivals read as one family.
                Theme.cardShape
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .keyframeAnimator(initialValue: 0.0, trigger: arrivals) { glow, opacity in
                        glow.opacity(opacity)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0.7, duration: 0.15)
                            LinearKeyframe(0, duration: 0.9)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// Hearts rising from a button that just sent one: something left your hands.
struct HeartBurst: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Rise {
        var opacity = 0.0
        var lift = 0.0
        var scale = 0.6
    }

    /// Each heart's sideways drift and size; they leave one after another.
    private static let hearts: [(drift: CGFloat, size: CGFloat)] = [(-26, 16), (0, 24), (24, 18)]

    var body: some View {
        if !reduceMotion {
            ZStack {
                ForEach(Self.hearts.indices, id: \.self) { index in
                    heart(index)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func heart(_ index: Int) -> some View {
        let heart = Self.hearts[index]
        let delay = Double(index) * Theme.Motion.stagger
        return Image(systemName: "heart.fill")
            .font(.system(size: heart.size))
            .foregroundStyle(Theme.accent)
            .keyframeAnimator(initialValue: Rise(), trigger: trigger) { view, value in
                view.opacity(value.opacity)
                    .offset(x: heart.drift * value.lift / -60, y: value.lift)
                    .scaleEffect(value.scale)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: delay)
                    LinearKeyframe(1, duration: 0.12)
                    LinearKeyframe(1, duration: 0.4)
                    LinearKeyframe(0, duration: 0.4)
                }
                KeyframeTrack(\.lift) {
                    LinearKeyframe(0, duration: delay)
                    CubicKeyframe(-60, duration: 0.95)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.6, duration: delay)
                    SpringKeyframe(1.15, duration: 0.3)
                    CubicKeyframe(0.85, duration: 0.65)
                }
            }
    }
}
