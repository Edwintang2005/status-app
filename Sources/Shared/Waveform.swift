import SwiftUI

/// Helpers for the loudness envelopes carried on voice-memo `Moment`s.
enum Waveform {
    /// Buckets samples down to a fixed count, taking each bucket's peak —
    /// means flatten speech into mush; peaks keep syllables visible.
    static func condense(_ samples: [Double], into count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard samples.count > count else { return samples }

        let bucket = Double(samples.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * bucket)
            let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucket)))
            return samples[start..<end].max() ?? 0
        }
    }

    /// Drawn when a memo carries no samples (sent from a pre-waveform build).
    /// Flat and even reads as "no shape recorded", not somebody's voice.
    static func flat(count: Int) -> [Double] {
        Array(repeating: 0.3, count: max(1, count))
    }
}

/// A row of rounded bars, one per sample. In Shared because the widget draws it
/// too; bars divide the width rather than measure it — cheap enough for the widget's memory budget.
struct WaveformBars: View {
    /// `0...1`, oldest first. Empty falls back to `Waveform.flat`.
    var levels: [Double]
    /// `0...1` playback position. Bars before it take `tint`, the rest
    /// `trackTint`. `nil` tints everything the same.
    var progress: Double?
    var tint: Color = Theme.accent
    var trackTint: Color = Theme.accent.opacity(0.25)
    var spacing: CGFloat = 2
    /// Fraction of height the quietest bar still occupies — silence is a dot, not a gap.
    var floorFraction: CGFloat = 0.12
    /// Ceiling on bar width — a handful of samples would otherwise split the
    /// full width into slabs.
    var maxBarWidth: CGFloat = 7

    private var bars: [Double] {
        levels.isEmpty ? Waveform.flat(count: 32) : levels
    }

    var body: some View {
        GeometryReader { geometry in
            // Bars clamp to a 1pt minimum, so condense to what fits rather than
            // spilling past a narrow tile.
            let capacity = max(1, Int((geometry.size.width + spacing) / (1 + spacing)))
            let bars = bars.count > capacity ? Waveform.condense(bars, into: capacity) : bars
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                    Capsule(style: .continuous)
                        .fill(color(at: index, of: bars.count))
                        .frame(width: barWidth(for: bars.count, in: geometry.size.width),
                               height: height(for: level, in: geometry.size.height))
                }
            }
            // Centred, so a too-narrow row doesn't hug the leading edge.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func barWidth(for count: Int, in available: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let gaps = spacing * CGFloat(count - 1)
        let even = (available - gaps) / CGFloat(count)
        return max(1, min(maxBarWidth, even))
    }

    private func height(for level: Double, in available: CGFloat) -> CGFloat {
        let clamped = CGFloat(max(0, min(1, level)))
        return available * (floorFraction + (1 - floorFraction) * clamped)
    }

    private func color(at index: Int, of count: Int) -> Color {
        guard let progress, count > 0 else { return tint }
        // `+1` so the bar under the playhead lights as it's reached, not after.
        return Double(index + 1) / Double(count) <= progress ? tint : trackTint
    }
}

#if DEBUG
#Preview("Waveform") {
    VStack(spacing: 24) {
        WaveformBars(levels: (0..<48).map { abs(sin(Double($0) / 3)) * 0.9 + 0.1 },
                     progress: 0.4)
            .frame(height: 60)
        WaveformBars(levels: [], progress: nil)
            .frame(height: 40)
    }
    .padding()
}
#endif
