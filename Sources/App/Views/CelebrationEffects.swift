import SwiftUI

// The celebration styles' particles; `CelebrationOverlay` stages them and
// `CelebrationMotion` decides where they go. Every layer counts from when it is
// inserted, stops itself within `CelebrationBeats.particleBudget`, and fades
// what crosses `zone` (the words).

enum CelebrationPalette {
    static let gold = Color(red: 0.98, green: 0.74, blue: 0.16)
    /// Saturated enough to read on the pink backdrop.
    static let confetti: [Color] = [Theme.accent, Theme.warm, Theme.mint, gold,
                                    Color(red: 0.56, green: 0.36, blue: 0.86), Color(red: 0.13, green: 0.62, blue: 0.56)]
    static let confettiGlyphs = ["💗", "🎉", "✨", "💞"]
    static let trophy: [Color] = [Color(red: 1.0, green: 0.80, blue: 0.30), Color(red: 0.93, green: 0.62, blue: 0.10),
                                  Color(red: 1.0, green: 0.90, blue: 0.55), Theme.warm]
    static let trophyGlyphs = ["⭐️", "✨", "🌟"]
    /// Outlines the gold pieces so they read on the gold glow.
    static let amberEdge = Color(red: 0.62, green: 0.36, blue: 0.04)
    static let hearts: [Color] = [Theme.accent, Theme.accentBright, Color(red: 0.95, green: 0.45, blue: 0.65),
                                  Color(red: 0.70, green: 0.15, blue: 0.30)]
    static let heartGlyphs = ["💗", "💖", "💞"]
    static let fireworks: [Color] = [Color(red: 1.0, green: 0.82, blue: 0.35), Theme.accentBright, Theme.mint,
                                     Theme.warm, Color(red: 0.85, green: 0.55, blue: 1.0), Color(white: 0.95)]
}

/// The shapes every layer draws, so the still scatter matches the moving one.
enum PieceArt {
    static func strip(size: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: -size / 2, y: -size, width: size, height: size * 2), cornerRadius: size * 0.3)
    }

    /// A heart centred on the origin, `size` across.
    static func heart(size: CGFloat) -> Path {
        let s = size, o = -size / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o + x * s, y: o + y * s) }
        var path = Path()
        path.move(to: p(0.5, 0.95))
        path.addCurve(to: p(0.05, 0.38), control1: p(0.30, 0.80), control2: p(0.05, 0.62))
        path.addCurve(to: p(0.28, 0.08), control1: p(0.05, 0.18), control2: p(0.15, 0.08))
        path.addCurve(to: p(0.5, 0.22), control1: p(0.40, 0.08), control2: p(0.48, 0.15))
        path.addCurve(to: p(0.72, 0.08), control1: p(0.52, 0.15), control2: p(0.60, 0.08))
        path.addCurve(to: p(0.95, 0.38), control1: p(0.85, 0.08), control2: p(0.95, 0.18))
        path.addCurve(to: p(0.5, 0.95), control1: p(0.95, 0.62), control2: p(0.70, 0.80))
        path.closeSubpath()
        return path
    }

    /// Six arms with a pair of branches on each, centred on the origin.
    static func flake(size: CGFloat) -> Path {
        let r = size / 2
        var path = Path()
        for arm in 0..<6 {
            let a = Double(arm) * .pi / 3
            let tip = CGPoint(x: cos(a) * r, y: sin(a) * r)
            path.move(to: .zero)
            path.addLine(to: tip)
            let joint = CGPoint(x: cos(a) * r * 0.55, y: sin(a) * r * 0.55)
            for side in [-1.0, 1.0] {
                let b = a + side * .pi / 4
                path.move(to: joint)
                path.addLine(to: CGPoint(x: joint.x + cos(b) * r * 0.3, y: joint.y + sin(b) * r * 0.3))
            }
        }
        return path
    }

    static func drawFlake(_ context: inout GraphicsContext, size: CGFloat, opacity: Double) {
        context.stroke(flake(size: size), with: .color(.white.opacity(opacity)),
                       style: StrokeStyle(lineWidth: max(1, size * 0.09), lineCap: .round))
    }

    static func dot(_ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
    }

    /// A four-pointed star, for the trophy's still scatter.
    static func star(size: CGFloat) -> Path {
        let r = size / 2, w = size * 0.14
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: w, y: -w))
        path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: w, y: w))
        path.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -w, y: w))
        path.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -w, y: -w))
        return path
    }
}

/// Runs `content` against the seconds since insertion, then removes itself.
struct ParticleClock<Content: View>: View {
    var lasts = CelebrationBeats.particleBudget
    @ViewBuilder let content: (Double) -> Content

    @State private var started = Date()
    @State private var finished = false

    var body: some View {
        if !finished {
            TimelineView(.animation) { timeline in
                content(timeline.date.timeIntervalSince(started))
            }
            .task {
                try? await Task.sleep(for: .seconds(lasts))
                if !Task.isCancelled { finished = true }
            }
        }
    }
}

// MARK: - Confetti

struct ConfettiLayer: View {
    let pieces: [ConfettiPiece]
    var palette = CelebrationPalette.confetti
    var glyphs = CelebrationPalette.confettiGlyphs
    var edge: Color?
    var zone: CGRect = .zero

    private static let glyphSize: CGFloat = 24

    var body: some View {
        ParticleClock { elapsed in
            Canvas { context, size in
                let resolved = glyphs.indices.map { context.resolveSymbol(id: $0) }
                for (index, piece) in pieces.enumerated() {
                    let t = elapsed - piece.launch
                    let opacity = ConfettiPhysics.opacity(t: t, life: piece.life)
                    guard opacity > 0 else { continue }
                    let seed = Double(index) * 1.7
                    let move = ConfettiPhysics.offset(velocity: piece.velocity, sway: piece.sway, seed: seed, t: t)
                    let point = CGPoint(x: piece.origin.x + move.dx, y: piece.origin.y + move.dy)
                    guard point.y < size.height + 40, point.x > -60, point.x < size.width + 60 else { continue }

                    context.drawLayer { layer in
                        layer.opacity = opacity * ClearZone.fade(at: point, zone: zone)
                        layer.translateBy(x: point.x, y: point.y)
                        layer.rotate(by: .radians(piece.spin * t * 2 * .pi + seed))
                        if let glyph = piece.glyph, resolved.indices.contains(glyph), let symbol = resolved[glyph] {
                            let scale = piece.size * 1.9 / Self.glyphSize
                            layer.scaleBy(x: scale, y: scale)
                            layer.draw(symbol, at: .zero)
                        } else {
                            let turn = ConfettiPhysics.flutter(flip: piece.flip, seed: seed, t: t)
                            layer.scaleBy(x: turn, y: 1)
                            let path = PieceArt.strip(size: piece.size)
                            // Edge-on, a piece catches less light.
                            layer.fill(path, with: .color(palette[piece.color % palette.count].opacity(0.7 + 0.3 * turn)))
                            if let edge { layer.stroke(path, with: .color(edge), lineWidth: 1) }
                        }
                    }
                }
            } symbols: {
                ForEach(glyphs.indices, id: \.self) { index in
                    Text(glyphs[index]).font(.system(size: Self.glyphSize)).tag(index)
                }
            }
        }
    }
}

/// Cannon confetti sized to wherever it is placed: the anniversary count's milestones.
struct CannonConfetti: View {
    @State private var pieces: [ConfettiPiece] = []

    var body: some View {
        GeometryReader { geometry in
            if pieces.isEmpty {
                Color.clear.onAppear {
                    var rng = SystemRandomNumberGenerator()
                    pieces = ConfettiPiece.cannons(in: geometry.size, palette: CelebrationPalette.confetti.count,
                                                   glyphs: CelebrationPalette.confettiGlyphs.count, using: &rng)
                }
            } else {
                ConfettiLayer(pieces: pieces)
            }
        }
    }
}

// MARK: - Hearts

/// A heart blooming out from the hero, then rising.
struct HeartPiece {
    let start: CGPoint
    /// Where the bloom carries it, relative to `start`.
    let outward: CGVector
    let launch: Double
    /// Points per second once the bloom is spent.
    let rise: Double
    let size: CGFloat
    /// Far hearts are faint, near ones solid.
    let strength: Double
    let sway: Double
    let swaySpeed: Double
    let color: Int
    let glyph: Int?

    static let bloomTime = 0.9

    /// Three depths: small, faint and slow behind; large and quick in front.
    static func bloom(around center: CGPoint, count: Int = 24) -> [HeartPiece] {
        let tiers: [(size: ClosedRange<CGFloat>, strength: Double, rise: ClosedRange<Double>, reach: ClosedRange<Double>)] = [
            (10...14, 0.45, 25...35, 70...120),
            (16...22, 0.75, 45...60, 100...170),
            (26...34, 0.95, 70...95, 130...200),
        ]
        return (0..<count).map { index in
            // 8 far, 10 middle, 6 near.
            let tier = tiers[index < 8 ? 0 : index < 18 ? 1 : 2]
            let angle = Double.random(in: 0..<(2 * .pi))
            let reach = Double.random(in: tier.reach)
            return HeartPiece(start: CGPoint(x: center.x + .random(in: -20...20), y: center.y + .random(in: -20...20)),
                              outward: CGVector(dx: cos(angle) * reach, dy: sin(angle) * reach * 0.8),
                              launch: .random(in: 0..<0.5), rise: .random(in: tier.rise),
                              size: .random(in: tier.size), strength: tier.strength,
                              sway: .random(in: 8...22), swaySpeed: .random(in: 1.0...2.0),
                              color: index % CelebrationPalette.hearts.count,
                              glyph: index % 5 == 0 ? (index / 5) % CelebrationPalette.heartGlyphs.count : nil)
        }
    }
}

struct HeartBloomLayer: View {
    let pieces: [HeartPiece]
    var zone: CGRect = .zero

    var body: some View {
        ParticleClock { elapsed in
            Canvas { context, _ in
                let glyphs = CelebrationPalette.heartGlyphs.indices.map { context.resolveSymbol(id: $0) }
                let life = CelebrationBeats.particleBudget - 0.3
                for (index, piece) in pieces.enumerated() {
                    let t = elapsed - piece.launch
                    guard t >= 0, t < life - piece.launch else { continue }
                    let bloom = 1 - pow(1 - min(1, t / HeartPiece.bloomTime), 3)
                    let floating = max(0, t - HeartPiece.bloomTime * 0.4)
                    let point = CGPoint(
                        x: piece.start.x + piece.outward.dx * bloom
                            + sin(t * piece.swaySpeed + Double(index)) * piece.sway * min(1, floating),
                        y: piece.start.y + piece.outward.dy * bloom - piece.rise * floating)
                    let opacity = min(1, t / 0.15) * min(1, (life - piece.launch - t) / ConfettiPhysics.fadeOut)
                    context.drawLayer { layer in
                        layer.opacity = opacity * piece.strength * ClearZone.fade(at: point, zone: zone)
                        layer.translateBy(x: point.x, y: point.y)
                        layer.rotate(by: .degrees(sin(t * 1.3 + Double(index)) * 10))
                        if let glyph = piece.glyph, glyphs.indices.contains(glyph), let symbol = glyphs[glyph] {
                            layer.scaleBy(x: piece.size / 24, y: piece.size / 24)
                            layer.draw(symbol, at: .zero)
                        } else {
                            layer.fill(PieceArt.heart(size: piece.size),
                                       with: .color(CelebrationPalette.hearts[piece.color]))
                        }
                    }
                }
            } symbols: {
                ForEach(CelebrationPalette.heartGlyphs.indices, id: \.self) { index in
                    Text(CelebrationPalette.heartGlyphs[index]).font(.system(size: 24)).tag(index)
                }
            }
        }
    }
}

// MARK: - Snow

/// A flake at one of three depths, already falling when the layer starts.
struct SnowFlake {
    /// 0 far, 1 middle, 2 near.
    let depth: Int
    /// Starting place, 0…1 across and down: the fall is pre-warmed.
    let x: Double
    let y: Double
    let speed: Double
    let size: CGFloat
    let drawn: Bool
    let sway: Double
    let swaySpeed: Double
    let spin: Double
    /// When it starts to thin out.
    let fadeAt: Double

    static func fall() -> [SnowFlake] {
        func flakes(_ count: Int, depth: Int, speed: ClosedRange<Double>, size: ClosedRange<CGFloat>,
                    drawnEvery: Int) -> [SnowFlake] {
            (0..<count).map { index in
                SnowFlake(depth: depth, x: .random(in: 0...1), y: .random(in: 0...1),
                          speed: .random(in: speed), size: .random(in: size), drawn: index % drawnEvery == 0,
                          sway: .random(in: 6...22), swaySpeed: .random(in: 0.5...1.3),
                          spin: .random(in: -0.4...0.4), fadeAt: .random(in: 4.0...6.0))
            }
        }
        return flakes(45, depth: 0, speed: 25...40, size: 2...3.4, drawnEvery: .max)
            + flakes(30, depth: 1, speed: 45...70, size: 9...14, drawnEvery: 3)
            + flakes(10, depth: 2, speed: 90...130, size: 18...26, drawnEvery: 1)
    }
}

struct SnowLayer: View {
    let flakes: [SnowFlake]
    var zone: CGRect = .zero

    private static let strength = [0.45, 0.8, 0.92]

    /// One gust, pushing the near flakes furthest.
    private static func gust(_ t: Double) -> Double {
        let u = (t - 1.8) / 1.8
        return u > 0 && u < 1 ? 70 * sin(.pi * u) : 0
    }

    var body: some View {
        ParticleClock { t in
            Canvas { context, size in
                let span = size.height + 40
                for depth in 0..<3 {
                    context.drawLayer { group in
                        // Near flakes sit in front of the lens: a touch soft.
                        if depth == 2 { group.addFilter(.blur(radius: 1.2)) }
                        for flake in flakes where flake.depth == depth {
                            let fade = min(1, t / 0.6) * min(1, max(0, 1 - (t - flake.fadeAt) / ConfettiPhysics.fadeOut))
                            guard fade > 0 else { continue }
                            let y = (flake.y * span + flake.speed * t).truncatingRemainder(dividingBy: span) - 20
                            let x = flake.x * size.width + sin(t * flake.swaySpeed + flake.x * 9) * flake.sway
                                + Self.gust(t) * Double(depth + 1) / 3
                            let point = CGPoint(x: x, y: y)
                            group.drawLayer { layer in
                                layer.opacity = fade * Self.strength[depth] * ClearZone.fade(at: point, zone: zone)
                                layer.translateBy(x: x, y: y)
                                if flake.drawn {
                                    layer.rotate(by: .radians(flake.spin * t))
                                    PieceArt.drawFlake(&layer, size: flake.size, opacity: 1)
                                } else {
                                    layer.fill(PieceArt.dot(flake.size / 2), with: .color(.white))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Fireworks

/// Rockets with trails climb from the bottom and bloom in light.
struct FireworksLayer: View {
    let show: FireworkShow
    var zone: CGRect = .zero

    var body: some View {
        ParticleClock(lasts: show.duration + 0.2) { elapsed in
            Canvas { context, size in
                context.blendMode = .plusLighter
                for burst in show.bursts {
                    let color = CelebrationPalette.fireworks[burst.color % CelebrationPalette.fireworks.count]
                    let t = elapsed - burst.at
                    let center = CGPoint(x: burst.center.x * size.width, y: burst.center.y * size.height)
                    if t < 0, t > -FireworkShow.climb {
                        rocket(&context, color: color, to: center, height: size.height, t: t)
                        continue
                    }
                    guard t >= 0, t < FireworkShow.life else { continue }
                    // The sky lifts faintly as it bursts; never a flash.
                    if t < 0.35 {
                        let glow = 0.12 * (1 - t / 0.35)
                        context.fill(Path(CGRect(origin: .zero, size: size)),
                                     with: .radialGradient(Gradient(colors: [color.opacity(glow), .clear]),
                                                           center: center, startRadius: 0, endRadius: size.width * 0.8))
                    }
                    sparks(&context, burst: burst, color: color, center: center,
                           reach: burst.reach * size.width, t: t)
                }
            }
        }
    }

    private func rocket(_ context: inout GraphicsContext, color: Color, to center: CGPoint, height: CGFloat, t: Double) {
        // A fading trail: the rocket where it was a moment ago.
        for step in 0..<6 {
            let p = 1 + (t - Double(step) * 0.03) / FireworkShow.climb
            guard p > 0 else { continue }
            let eased = 1 - pow(1 - p, 2)
            let y = height + (center.y - height) * eased
            let radius = 2.2 - CGFloat(step) * 0.3
            context.fill(PieceArt.dot(radius).offsetBy(dx: center.x, dy: y),
                         with: .color(color.opacity(0.9 - Double(step) * 0.15)))
        }
    }

    private func sparks(_ context: inout GraphicsContext, burst: FireworkShow.Burst, color: Color,
                        center: CGPoint, reach: Double, t: Double) {
        let spread = 1 - pow(1 - min(t / 0.9, 1), 3)
        let fall = 34 * t * t
        let fade = max(0, 1 - t / FireworkShow.life)
        let late = t > FireworkShow.life * 0.55
        // Two shells, an outer and a tighter inner one, so a burst fills in.
        for index in 0..<(burst.sparks * 2) {
            let inner = index >= burst.sparks
            let angle = 2 * Double.pi * Double(index % burst.sparks) / Double(burst.sparks) + (inner ? 0.09 : 0)
            // A fixed per-spark reach, so a burst reads as a bloom, not a ring.
            let hash = sin(Double(index) * 12.9898 + burst.at * 78.233) * 43_758.5453
            let jitter = (inner ? 0.4 : 0.7) + 0.3 * (hash - hash.rounded(.down))
            let twinkle = late ? 0.5 + 0.5 * sin(t * 28 + Double(index) * 1.9) : 1
            let head = reach * spread * jitter
            // A streak back along the path it came, shortening as it slows.
            let tail = reach * max(0, spread - 0.16 * (1 - spread) - 0.04) * jitter
            let point = CGPoint(x: center.x + cos(angle) * head, y: center.y + sin(angle) * head + fall)
            let from = CGPoint(x: center.x + cos(angle) * tail, y: center.y + sin(angle) * tail + fall * 0.9)
            let alpha = fade * twinkle * (inner ? 0.8 : 1) * ClearZone.fade(at: point, zone: zone)
            guard alpha > 0.01 else { continue }
            var streak = Path()
            streak.move(to: from)
            streak.addLine(to: point)
            context.stroke(streak, with: .color(color.opacity(alpha * 0.7)),
                           style: StrokeStyle(lineWidth: inner ? 1.3 : 1.8, lineCap: .round))
            context.fill(PieceArt.dot(5).offsetBy(dx: point.x, dy: point.y), with: .color(color.opacity(alpha * 0.2)))
            context.fill(PieceArt.dot(inner ? 1.4 : 1.9).offsetBy(dx: point.x, dy: point.y),
                         with: .color(color.opacity(alpha)))
        }
    }
}

/// The fireworks hero, drawn: Apple's 🎆 is a framed photo tile at this size.
struct BurstMark: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let colors = [CelebrationPalette.gold, Theme.accentBright, Color(red: 0.85, green: 0.55, blue: 1.0)]
            context.fill(PieceArt.dot(size.width * 0.16).offsetBy(dx: center.x, dy: center.y),
                         with: .radialGradient(Gradient(colors: [.white, CelebrationPalette.gold.opacity(0)]),
                                               center: center, startRadius: 0, endRadius: size.width * 0.16))
            for ray in 0..<16 {
                let angle = Double(ray) * .pi / 8
                let long = ray.isMultiple(of: 2)
                let inner = size.width * 0.14, outer = size.width * (long ? 0.46 : 0.34)
                var path = Path()
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                let color = colors[ray % colors.count]
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: long ? 3.5 : 2.5, lineCap: .round))
                context.fill(PieceArt.dot(long ? 2.6 : 1.8).offsetBy(dx: center.x + cos(angle) * (outer + 5),
                                                                     dy: center.y + sin(angle) * (outer + 5)),
                             with: .color(color))
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityHidden(true)
    }
}

// MARK: - Reduce Motion

/// The style's pieces, scattered and still: a celebration that doesn't move.
struct StillScatter: View {
    let style: CelebrationStyle
    var zone: CGRect = .zero

    var body: some View {
        Canvas { context, size in
            var rng = SeededGenerator(seed: UInt64(CelebrationStyle.allCases.firstIndex(of: style) ?? 0) &+ 11)
            let keepOut = zone.insetBy(dx: -24, dy: -24)
            var placed = 0
            for _ in 0..<120 where placed < 38 {
                let point = CGPoint(x: .random(in: 12...(max(13, size.width - 12)), using: &rng),
                                    y: .random(in: 40...(max(41, size.height - 40)), using: &rng))
                let turn = Double.random(in: 0..<(2 * .pi), using: &rng)
                let pick = Int.random(in: 0..<12, using: &rng)
                // Clear of the words, and of the footer's quiet lines.
                let footer = point.y > size.height - 190 && point.x > 40 && point.x < size.width - 40
                guard !keepOut.contains(point), !footer else { continue }
                placed += 1
                context.drawLayer { layer in
                    layer.translateBy(x: point.x, y: point.y)
                    layer.rotate(by: .radians(turn))
                    draw(&layer, pick: pick)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ layer: inout GraphicsContext, pick: Int) {
        switch style {
        case .hearts:
            let size = CGFloat(12 + pick * 2)
            layer.opacity = pick < 4 ? 0.5 : 0.85
            layer.fill(PieceArt.heart(size: size), with: .color(CelebrationPalette.hearts[pick % 4]))
        case .snow:
            layer.opacity = pick < 5 ? 0.45 : 0.9
            if pick < 5 {
                layer.fill(PieceArt.dot(1.6), with: .color(.white))
            } else {
                PieceArt.drawFlake(&layer, size: CGFloat(10 + pick), opacity: 1)
            }
        case .fireworks:
            let color = CelebrationPalette.fireworks[pick % CelebrationPalette.fireworks.count]
            layer.fill(PieceArt.dot(5), with: .color(color.opacity(0.25)))
            layer.fill(PieceArt.dot(1.8), with: .color(color))
        case .trophy:
            if pick < 4 {
                layer.fill(PieceArt.star(size: 14), with: .color(CelebrationPalette.gold))
            } else {
                let path = PieceArt.strip(size: 8)
                layer.fill(path, with: .color(CelebrationPalette.trophy[pick % 4]))
                layer.stroke(path, with: .color(CelebrationPalette.amberEdge), lineWidth: 1)
            }
        case .confetti, .birthday, .reveal:
            layer.fill(PieceArt.strip(size: 8),
                       with: .color(CelebrationPalette.confetti[pick % CelebrationPalette.confetti.count]))
        }
    }
}

// MARK: - The sender's taste

/// A small burst of a style's pieces: what the sender sees as their
/// celebration goes. Waits out a closing sheet first.
struct MiniBurst: View {
    let style: CelebrationStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pieces: [(angle: Double, speed: Double, spin: Double, pick: Int)] = (0..<18).map { index in
        (-Double.pi / 2 + .random(in: -1.3...1.3), .random(in: 160...300), .random(in: -2...2), index)
    }

    private static let delay = 0.35
    private static let life = 1.5

    var body: some View {
        if !reduceMotion {
            ParticleClock(lasts: Self.delay + Self.life) { elapsed in
                Canvas { context, size in
                    let t = elapsed - Self.delay
                    guard t > 0 else { return }
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let opacity = min(1, t / 0.08) * max(0, 1 - t / Self.life)
                    for piece in pieces {
                        let x = center.x + cos(piece.angle) * piece.speed * t
                        let y = center.y + sin(piece.angle) * piece.speed * t + 0.5 * 700 * t * t
                        context.drawLayer { layer in
                            layer.opacity = opacity
                            layer.translateBy(x: x, y: y)
                            layer.rotate(by: .radians(piece.spin * t))
                            draw(&layer, pick: piece.pick)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func draw(_ layer: inout GraphicsContext, pick: Int) {
        switch style {
        case .hearts: layer.fill(PieceArt.heart(size: 11), with: .color(CelebrationPalette.hearts[pick % 4]))
        case .snow: layer.stroke(PieceArt.flake(size: 11), with: .color(Theme.mint), lineWidth: 1.4)
        case .fireworks:
            let color = CelebrationPalette.fireworks[pick % 5]
            layer.fill(PieceArt.dot(2.2), with: .color(color))
        case .trophy: layer.fill(PieceArt.strip(size: 5), with: .color(CelebrationPalette.trophy[pick % 4]))
        case .confetti, .birthday, .reveal:
            layer.fill(PieceArt.strip(size: 5),
                       with: .color(CelebrationPalette.confetti[pick % CelebrationPalette.confetti.count]))
        }
    }
}
