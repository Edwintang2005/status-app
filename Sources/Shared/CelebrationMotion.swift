import CoreGraphics
import Foundation

// The celebration's timing and particle rules, pure so the tests can pin them;
// `CelebrationOverlay` and `CelebrationEffects` draw what these decide.

/// When each part of a celebration arrives, in seconds after it is staged.
enum CelebrationBeats {
    /// After the scene turns active: the launch or resume zoom is over by then.
    static let stageDelay = 0.55
    /// The hero starts moving once the backdrop has begun to bloom.
    static let heroStarts = 0.15
    /// Every style's particles are gone this long after they start.
    static let particleBudget = 7.0
    /// After the particles, the backdrop breathes this slowly, this much.
    static let breathPeriod = 4.0
    static let breathDepth = 0.06

    /// How long the hero takes to land: the trophy falls, the rest pop.
    static func travel(_ style: CelebrationStyle) -> Double {
        style == .trophy ? 0.42 : 0.25
    }

    /// The moment the hero lands; the haptic and most particles start here.
    static func impact(_ style: CelebrationStyle) -> Double {
        heroStarts + travel(style)
    }

    /// The words follow the hero, and the footer the words.
    static func words(afterImpact impact: Double) -> Double { impact + 0.25 }
    static func footer(afterWords words: Double) -> Double { words + 0.5 }

    /// The hearts' two lub-dubs, as (seconds after impact, heavy).
    static let heartbeats: [(at: Double, heavy: Bool)] = [(0, true), (0.18, false), (0.6, true), (0.78, false)]
}

/// Particles crossing the headline fade, so they pass behind the words.
enum ClearZone {
    static let floor = 0.2
    /// How far outside the zone a piece is back to full strength.
    static let ramp: CGFloat = 24

    /// The opacity factor for a piece at `point`; 1 when there is no zone.
    static func fade(at point: CGPoint, zone: CGRect) -> Double {
        guard !zone.isEmpty else { return 1 }
        let dx = max(zone.minX - point.x, 0, point.x - zone.maxX)
        let dy = max(zone.minY - point.y, 0, point.y - zone.maxY)
        let distance = hypot(dx, dy)
        return min(1, floor + (1 - floor) * Double(distance / ramp))
    }
}

// MARK: - Confetti

/// One piece of confetti: launched, slowed by the air, then floating down.
struct ConfettiPiece: Sendable {
    let origin: CGPoint
    /// Points per second, y down.
    let velocity: CGVector
    /// Seconds after the layer starts.
    let launch: Double
    /// Seconds from launch until it has faded away.
    let life: Double
    let size: CGFloat
    /// Turns per second about its long axis: the fake 3D flutter.
    let flip: Double
    /// Turns per second in the plane.
    let spin: Double
    /// Side-to-side reach once it floats.
    let sway: CGFloat
    /// An index into the layer's palette.
    let color: Int
    /// An index into the layer's glyphs, for the few emoji pieces.
    let glyph: Int?
}

enum ConfettiPhysics {
    /// Linear air drag, per second; terminal velocity is `gravity / drag`.
    static let drag = 1.6
    static let gravity = 260.0
    static let fadeOut = 0.8

    /// Where a piece is `t` seconds after launch, relative to its origin.
    static func offset(velocity: CGVector, sway: CGFloat, seed: Double, t: Double) -> CGVector {
        let k = drag, g = gravity
        let slowing = (1 - exp(-k * t)) / k
        let x = Double(velocity.dx) * slowing
        let y = g / k * t + (Double(velocity.dy) - g / k) * slowing
        // The flutter sways more as the launch speed bleeds away.
        let floating = min(1, t / 1.2)
        return CGVector(dx: x + Double(sway) * sin(t * 2.2 + seed) * floating, dy: y)
    }

    /// In fast, out over the last `fadeOut` seconds of its life.
    static func opacity(t: Double, life: Double) -> Double {
        guard t >= 0, t < life else { return 0 }
        return min(1, t / 0.08) * min(1, (life - t) / fadeOut)
    }

    /// The piece's apparent width as it turns about its long axis.
    static func flutter(flip: Double, seed: Double, t: Double) -> Double {
        max(0.12, abs(cos(t * flip * 2 * .pi + seed)))
    }
}

extension ConfettiPiece {
    /// Share of a cannon volley that leaves in the opening `volley` seconds.
    static let volley = 0.3

    /// Two cannons at the bottom corners, then a light fall from the top.
    static func cannons(in size: CGSize, count: Int = 100, trickle: Int = 24, palette: Int, glyphs: Int,
                        using rng: inout some RandomNumberGenerator) -> [ConfettiPiece] {
        let budget = CelebrationBeats.particleBudget
        var pieces: [ConfettiPiece] = (0..<count).map { index in
            let left = index.isMultiple(of: 2)
            // Up and inward, crossing the middle.
            let angle = Double.random(in: 0.21...0.66, using: &rng)
            let speed = Double(size.height) * .random(in: 0.85...1.55, using: &rng)
            let launch = Double.random(in: 0..<volley, using: &rng)
            return ConfettiPiece(origin: CGPoint(x: left ? -10 : size.width + 10, y: size.height + 10),
                                 velocity: CGVector(dx: (left ? 1 : -1) * speed * sin(angle), dy: -speed * cos(angle)),
                                 launch: launch, life: budget - launch,
                                 size: .random(in: 7...12, using: &rng), flip: .random(in: 0.6...1.8, using: &rng),
                                 spin: .random(in: -0.5...0.5, using: &rng), sway: .random(in: 10...28, using: &rng),
                                 color: index % palette, glyph: Self.glyph(index, glyphs))
        }
        pieces += (0..<trickle).map { index in
            let launch = Double.random(in: volley...3.2, using: &rng)
            return ConfettiPiece(origin: CGPoint(x: .random(in: 0...size.width, using: &rng), y: -20),
                                 velocity: CGVector(dx: .random(in: -30...30, using: &rng), dy: .random(in: 20...80, using: &rng)),
                                 launch: launch, life: budget - launch,
                                 size: .random(in: 7...11, using: &rng), flip: .random(in: 0.6...1.6, using: &rng),
                                 spin: .random(in: -0.4...0.4, using: &rng), sway: .random(in: 14...30, using: &rng),
                                 color: index % palette, glyph: nil)
        }
        return pieces
    }

    /// A fan from one point: the trophy's landing, the top of the cake.
    static func burst(from point: CGPoint, in size: CGSize, count: Int = 70, spread: Double = 1.2,
                      palette: Int, glyphs: Int, using rng: inout some RandomNumberGenerator) -> [ConfettiPiece] {
        (0..<count).map { index in
            let angle = -Double.pi / 2 + .random(in: -spread...spread, using: &rng)
            let speed = Double(size.height) * .random(in: 0.55...1.1, using: &rng)
            let launch = Double.random(in: 0..<0.12, using: &rng)
            return ConfettiPiece(origin: point,
                                 velocity: CGVector(dx: speed * cos(angle), dy: speed * sin(angle)),
                                 launch: launch, life: CelebrationBeats.particleBudget - 0.5 - launch,
                                 size: .random(in: 7...12, using: &rng), flip: .random(in: 0.6...1.8, using: &rng),
                                 spin: .random(in: -0.6...0.6, using: &rng), sway: .random(in: 10...26, using: &rng),
                                 color: index % palette, glyph: Self.glyph(index, glyphs))
        }
    }

    /// Outward from a rectangle's edges: the reveal's card.
    static func rim(of rect: CGRect, in size: CGSize, count: Int = 80, palette: Int, glyphs: Int,
                    using rng: inout some RandomNumberGenerator) -> [ConfettiPiece] {
        (0..<count).map { index in
            let along = Double.random(in: 0..<1, using: &rng)
            let point: CGPoint
            let normal: CGVector
            switch index % 4 {
            case 0: point = CGPoint(x: rect.minX + rect.width * along, y: rect.minY); normal = CGVector(dx: 0, dy: -1)
            case 1: point = CGPoint(x: rect.maxX, y: rect.minY + rect.height * along); normal = CGVector(dx: 1, dy: -0.4)
            case 2: point = CGPoint(x: rect.minX + rect.width * along, y: rect.maxY); normal = CGVector(dx: 0, dy: -0.2)
            default: point = CGPoint(x: rect.minX, y: rect.minY + rect.height * along); normal = CGVector(dx: -1, dy: -0.4)
            }
            let speed = Double(size.height) * .random(in: 0.35...0.75, using: &rng)
            let launch = Double.random(in: 0..<0.15, using: &rng)
            return ConfettiPiece(origin: point,
                                 velocity: CGVector(dx: normal.dx * speed, dy: normal.dy * speed - size.height * 0.3),
                                 launch: launch, life: CelebrationBeats.particleBudget - 0.5 - launch,
                                 size: .random(in: 7...11, using: &rng), flip: .random(in: 0.6...1.8, using: &rng),
                                 spin: .random(in: -0.6...0.6, using: &rng), sway: .random(in: 10...24, using: &rng),
                                 color: index % palette, glyph: Self.glyph(index, glyphs))
        }
    }

    /// Roughly one in six is an emoji, so they stay a garnish.
    private static func glyph(_ index: Int, _ glyphs: Int) -> Int? {
        glyphs > 0 && index % 6 == 0 ? (index / 6) % glyphs : nil
    }
}

// MARK: - Fireworks

/// The fireworks show: a few single bursts, then a finale of three together.
struct FireworkShow: Sendable {
    struct Burst: Sendable {
        /// Where it bursts, in unit coordinates.
        let center: CGPoint
        /// Seconds after the show starts that it bursts.
        let at: Double
        let color: Int
        let sparks: Int
        /// The bloom's reach as a share of the screen's width.
        let reach: Double
    }

    /// How long a rocket climbs, and how long the sparks live.
    static let climb = 0.6
    static let life = 2.2
    /// Light ticks, one per burst, never more than this.
    static let maxHaptics = 5

    let bursts: [Burst]

    var duration: Double { (bursts.map(\.at).max() ?? 0) + Self.life }

    /// One tick per burst, in order, capped.
    var hapticTimes: [Double] { Array(bursts.map(\.at).sorted().prefix(Self.maxHaptics)) }

    /// Bursts stay in the top band or out at the sides, clear of the words.
    static func plan(palette: Int, using rng: inout some RandomNumberGenerator) -> FireworkShow {
        let singles = [0.5, 1.3, 2.1].map { $0 + .random(in: 0...0.15, using: &rng) }
        let times = singles + [3.0, 3.1, 3.25]
        let bursts = times.enumerated().map { index, at in
            let center: CGPoint
            if index % 3 == 2 {
                // Out to one side, a little lower.
                let left = Bool.random(using: &rng)
                center = CGPoint(x: left ? .random(in: 0.1...0.22, using: &rng) : .random(in: 0.78...0.9, using: &rng),
                                 y: .random(in: 0.3...0.48, using: &rng))
            } else {
                center = CGPoint(x: .random(in: 0.15...0.85, using: &rng), y: .random(in: 0.08...0.26, using: &rng))
            }
            return Burst(center: center, at: at, color: index % palette,
                         sparks: .random(in: 30...40, using: &rng), reach: .random(in: 0.22...0.34, using: &rng))
        }
        return FireworkShow(bursts: bursts)
    }
}

// MARK: - Randomness

/// SplitMix64: the still scatter lays out the same way on every redraw.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
