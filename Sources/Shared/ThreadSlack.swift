import SwiftUI

/// How the Together widget's red string hangs, in shares of its frame: where
/// it crosses, how deep each dip runs, which way up. Bounded so the curve stays
/// inside the frame; its two halves meet smoothly at the crossing.
struct ThreadSlack: Equatable, Sendable {
    var crossX = 0.55, crossY = 0.35
    var dipA = -0.1, dipB = 1.1, dipD = 0.2
    var flipped = false

    init() {}

    /// The same seed always hangs the same way.
    init(seed: Date) {
        var state = UInt64(bitPattern: Int64(seed.timeIntervalSince1970.rounded()))
        func next(_ range: ClosedRange<Double>) -> Double {
            // SplitMix64: a stable spread from one number.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return range.lowerBound + Double(z >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
        crossX = next(0.4...0.65)
        crossY = next(0.25...0.45)
        dipA = next(-0.15...0.05)
        dipB = next(0.95...1.15)
        dipD = next(0.1...0.35)
        flipped = next(0...1) < 0.5
    }

    func wave(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * (flipped ? 1 - y : y))
        }
        var path = Path()
        path.move(to: point(0, 0.6))
        path.addCurve(to: point(crossX, crossY),
                      control1: point(crossX * 0.36, dipA), control2: point(crossX * 0.64, dipB))
        // The second half leaves the crossing along the first's line: a smooth join.
        let lead = 0.4
        path.addCurve(to: point(1, 0.6),
                      control1: point(crossX + lead * crossX * 0.36, crossY + lead * (crossY - dipB)),
                      control2: point(crossX + (1 - crossX) * 0.8, dipD))
        return path
    }
}
