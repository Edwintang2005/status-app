import SwiftUI

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
    /// Fires once per gesture, so the enclosing screen can mark the memo heard.
    var onScrubStart: (() -> Void)? = nil

    @State private var isScrubbing = false

    private var progress: Double? {
        guard let audioURL, player.currentURL == audioURL else { return nil }
        return player.progress
    }

    var body: some View {
        GeometryReader { geometry in
            WaveformBars(levels: moment.waveform,
                         progress: progress,
                         tint: tint,
                         trackTint: trackTint,
                         spacing: spacing,
                         maxBarWidth: maxBarWidth)
                .contentShape(Rectangle())
                // High priority: a plain `.gesture` loses to the gallery pager's
                // pan and to an enclosing Button, and the scrub never fires.
                .highPriorityGesture(
                    DragGesture(minimumDistance: minimumDragDistance)
                        .onChanged { value in
                            guard let audioURL else { return }
                            if !isScrubbing {
                                isScrubbing = true
                                onScrubStart?()
                            }
                            let fraction = value.location.x / max(1, geometry.size.width)
                            player.seek(audioURL, to: fraction)
                        }
                        .onEnded { _ in isScrubbing = false }
                )
        }
    }
}
