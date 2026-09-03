import SwiftUI
import UIKit

/// A waveform that can be swiped to scrub playback. Wraps `WaveformBars` in a
/// drag gesture that maps touch position to a playback fraction; scrubbing an
/// idle memo starts it from that point. App-only — widget waveforms are static.
struct ScrubbableWaveform: View {
    let moment: Moment
    /// The playable file; scrubbing is inert until it's on this device.
    let audioURL: URL?
    let player: VoicePlayer
    var tint: Color = Theme.accent
    var trackTint: Color = Theme.accent.opacity(0.25)
    var spacing: CGFloat = 2
    var maxBarWidth: CGFloat = 7
    /// 0 makes a plain tap seek too; use ~10 inside a Button or pager so taps
    /// and page swipes still win.
    var minimumDragDistance: CGFloat = 0
    /// Inside a vertical ScrollView: a SwiftUI high-priority drag is
    /// omnidirectional and hijacks scrolls that start on the waveform, so use
    /// the UIKit pan that fails on vertical movement instead.
    var scrollSafe: Bool = false
    /// Fires once per gesture, so the enclosing screen can mark the memo heard.
    var onScrubStart: (() -> Void)? = nil

    @State private var isScrubbing = false

    private var progress: Double? {
        guard let audioURL, player.currentURL == audioURL else { return nil }
        return player.progress
    }

    var body: some View {
        GeometryReader { geometry in
            let bars = WaveformBars(levels: moment.waveform,
                                    progress: progress,
                                    tint: tint,
                                    trackTint: trackTint,
                                    spacing: spacing,
                                    maxBarWidth: maxBarWidth)
                .contentShape(Rectangle())
            Group {
                if scrollSafe {
                    bars.overlay {
                        HorizontalScrub { fraction in
                            scrub(to: fraction)
                        } onEnded: {
                            isScrubbing = false
                        }
                    }
                } else {
                    // High priority: a plain `.gesture` loses to the gallery pager's
                    // pan and to an enclosing Button, and the scrub never fires.
                    bars.highPriorityGesture(
                        DragGesture(minimumDistance: minimumDragDistance)
                            .onChanged { value in
                                scrub(to: value.location.x / max(1, geometry.size.width))
                            }
                            .onEnded { _ in isScrubbing = false }
                    )
                }
            }
                .accessibilityLabel("Playback position")
                .accessibilityValue(progress.map { String(localized: "\(Int($0 * 100)) percent") }
                                    ?? String(localized: "Not playing"))
                .accessibilityAdjustableAction { direction in
                    guard let audioURL else { return }
                    onScrubStart?()
                    player.seek(audioURL, by: direction == .increment ? 0.1 : -0.1)
                }
        }
    }
}

extension ScrubbableWaveform {
    private func scrub(to fraction: CGFloat) {
        guard let audioURL else { return }
        if !isScrubbing {
            isScrubbing = true
            onScrubStart?()
        }
        player.seek(audioURL, to: fraction)
    }
}

/// A transparent view carrying a pan that only recognises horizontal movement.
/// UIKit because SwiftUI's `DragGesture` can't fail after the fact: once it
/// has claimed the touch the enclosing ScrollView never scrolls. Taps pass
/// through to SwiftUI gestures on the ancestors.
struct HorizontalScrub: UIViewRepresentable {
    /// `0...1` across the view's width, on begin and every change.
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ScrubHostView()
        view.backgroundColor = .clear
        let pan = HorizontalPanGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        view.pan = pan
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: HorizontalScrub
        init(parent: HorizontalScrub) { self.parent = parent }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let fraction = gesture.location(in: view).x / max(1, view.bounds.width)
            switch gesture.state {
            case .began, .changed: parent.onChanged(min(1, max(0, fraction)))
            case .ended, .cancelled, .failed: parent.onEnded()
            default: break
            }
        }
    }
}

/// Hosts the pan and tells the enclosing scroll view to wait for it: without
/// the dependency both pans race to 10pt and the scroll view can win a
/// horizontal swipe, or ours a vertical one.
final class ScrubHostView: UIView {
    weak var pan: UIGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let pan else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollView.panGestureRecognizer.require(toFail: pan)
                return
            }
            ancestor = view.superview
        }
    }
}

/// Decides direction once the finger has moved far enough to mean it (a real
/// touch jitters sideways on the way down), then fails unless the movement is
/// clearly horizontal — so the ScrollView's own pan takes the touch.
final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    private var start: CGPoint?
    private static let decisionDistance: CGFloat = 8

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start, let point = touches.first?.location(in: view) {
            let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
            // Undecided: hold `super` back so the pan can't begin on a wobble.
            guard hypot(dx, dy) >= Self.decisionDistance else { return }
            if dx < dy * 1.5 {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        start = nil
        super.reset()
    }
}

extension VoicePlayer {
    /// Moves playback by a fraction of the memo — VoiceOver's swipe up/down on
    /// a waveform. An idle memo starts from that point, like a touch scrub.
    func seek(_ url: URL, by delta: Double) {
        let current = currentURL == url ? progress : 0
        seek(url, to: min(1, max(0, current + delta)))
    }
}
