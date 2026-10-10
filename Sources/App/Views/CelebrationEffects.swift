import SwiftUI

// The celebration styles' own pieces; `CelebrationOverlay` composes them.

// MARK: - Drift (hearts rising, snow falling)

/// One piece crossing the screen once per pass, swaying as it goes. Like
/// `ConfettiPiece`, its position is a pure function of elapsed time.
struct DriftPiece {
    /// Across the screen, 0…1.
    let x: Double
    /// Delay before its first pass, as a fraction of `travel`.
    let delay: Double
    /// Seconds to cross the screen.
    let travel: Double
    let sway: Double
    let swaySpeed: Double
    let size: CGFloat
    let spin: Double
    /// An index into the layer's glyphs, or `nil` for a plain dot.
    let glyph: Int?

    static let heartGlyphs = ["❤️", "💕", "💗", "💖", "💞"]
    static let snowGlyphs = ["❄️"]

    static func hearts(count: Int = 40) -> [DriftPiece] {
        (0..<count).map { index in
            DriftPiece(x: .random(in: 0.05...0.95), delay: .random(in: 0..<1),
                       travel: .random(in: 4.5...7.5), sway: .random(in: 14...36),
                       swaySpeed: .random(in: 1.2...2.4), size: .random(in: 16...32),
                       spin: .random(in: -0.15...0.15), glyph: index % heartGlyphs.count)
        }
    }

    static func snow(count: Int = 70) -> [DriftPiece] {
        (0..<count).map { index in
            // One flake in three is a glyph; the rest are soft dots.
            DriftPiece(x: .random(in: 0...1), delay: .random(in: 0..<1),
                       travel: .random(in: 6...11), sway: .random(in: 8...28),
                       swaySpeed: .random(in: 0.6...1.4),
                       size: index % 3 == 0 ? .random(in: 14...24) : .random(in: 3...7),
                       spin: .random(in: -0.3...0.3), glyph: index % 3 == 0 ? 0 : nil)
        }
    }
}

/// A few passes from `start`, then nothing: the timeline stops.
struct DriftLayer: View {
    let pieces: [DriftPiece]
    let glyphs: [String]
    /// Hearts float up from the bottom; snow falls from the top.
    let rising: Bool
    let start: Date
    var passes = 2

    @State private var finished = false

    private var duration: Double {
        (pieces.map { $0.travel * (Double(passes) + $0.delay) }.max() ?? 0)
    }

    var body: some View {
        if !finished {
            TimelineView(.animation) { timeline in
                canvas(elapsed: timeline.date.timeIntervalSince(start))
            }
            .task(id: start) {
                let left = duration - Date().timeIntervalSince(start)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                if !Task.isCancelled { finished = true }
            }
        }
    }

    private func canvas(elapsed: TimeInterval) -> some View {
        Canvas { context, size in
            let resolved = glyphs.indices.map { context.resolveSymbol(id: $0) }
            let span = size.height + 80
            for piece in pieces {
                let loops = elapsed / piece.travel - piece.delay
                guard loops >= 0, loops < Double(passes) else { continue }
                let progress = loops.truncatingRemainder(dividingBy: 1)
                let y = rising ? size.height + 40 - progress * span : -40 + progress * span
                let x = piece.x * size.width
                    + sin(elapsed * piece.swaySpeed + piece.delay * 2 * .pi) * piece.sway
                let opacity = min(1, progress / 0.08) * min(1, (1 - progress) / 0.15)

                context.drawLayer { layer in
                    layer.opacity = opacity
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(sin(elapsed * 1.3 + piece.delay * 6) * piece.spin * .pi))
                    if let index = piece.glyph, resolved.indices.contains(index), let glyph = resolved[index] {
                        let scale = piece.size / 24
                        layer.scaleBy(x: scale, y: scale)
                        layer.draw(glyph, at: .zero)
                    } else {
                        let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2,
                                          width: piece.size, height: piece.size)
                        layer.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.85)))
                    }
                }
            }
        } symbols: {
            ForEach(glyphs.indices, id: \.self) { index in
                Text(glyphs[index]).font(.system(size: 24)).tag(index)
            }
        }
    }
}

// MARK: - Fireworks

struct FireworkBurst {
    /// Where it bursts, in unit coordinates.
    let center: UnitPoint
    /// Seconds after the start that it bursts.
    let delay: Double
    let color: Color
    let sparks: Int
    let radius: CGFloat

    /// How long a rocket climbs, and how long the sparks live.
    static let climb: Double = 0.6
    static let life: Double = 2.0

    static func show(count: Int = 10) -> [FireworkBurst] {
        let colors = [Color(red: 1.0, green: 0.82, blue: 0.35), Theme.accentBright, Theme.mint,
                      Theme.warm, Color(red: 0.85, green: 0.55, blue: 1.0), Color.white]
        return (0..<count).map { index in
            FireworkBurst(center: UnitPoint(x: .random(in: 0.15...0.85), y: .random(in: 0.12...0.48)),
                          delay: Double(index) * 0.65 + .random(in: 0...0.3),
                          color: colors[index % colors.count],
                          sparks: .random(in: 26...38),
                          radius: .random(in: 90...150))
        }
    }
}

/// Rockets climb from the bottom and burst; each once, then the layer stops.
struct FireworksLayer: View {
    let bursts: [FireworkBurst]
    let start: Date

    @State private var finished = false

    private var duration: Double {
        (bursts.map(\.delay).max() ?? 0) + FireworkBurst.life + 0.2
    }

    var body: some View {
        if !finished {
            TimelineView(.animation) { timeline in
                canvas(elapsed: timeline.date.timeIntervalSince(start))
            }
            .task(id: start) {
                let left = duration - Date().timeIntervalSince(start)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                if !Task.isCancelled { finished = true }
            }
        }
    }

    private func canvas(elapsed: TimeInterval) -> some View {
        Canvas { context, size in
            for burst in bursts {
                let t = elapsed - burst.delay
                let center = CGPoint(x: burst.center.x * size.width, y: burst.center.y * size.height)
                if t < 0, t > -FireworkBurst.climb {
                    // The rocket: easing up to where it bursts.
                    let p = 1 + t / FireworkBurst.climb
                    let eased = 1 - pow(1 - p, 2)
                    let y = size.height + (center.y - size.height) * eased
                    let dot = CGRect(x: center.x - 2, y: y - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(burst.color.opacity(0.9)))
                    continue
                }
                guard t >= 0, t < FireworkBurst.life else { continue }
                let spread = 1 - pow(1 - min(t / 0.9, 1), 3)
                let fall = 30 * t * t
                let opacity = max(0, 1 - t / FireworkBurst.life)
                for index in 0..<burst.sparks {
                    let angle = 2 * Double.pi * Double(index) / Double(burst.sparks)
                    // A fixed per-spark reach, so a burst reads as a bloom, not a ring.
                    let jitter = 0.7 + 0.3 * abs(sin(Double(index) * 12.9898 + burst.delay * 78.233))
                    for (reach, sparkSize, fade) in [(1.0, 4.2, 1.0), (0.86, 3.0, 0.55), (0.72, 2.0, 0.25)] {
                        let r = burst.radius * spread * reach * jitter
                        let point = CGPoint(x: center.x + cos(angle) * r,
                                            y: center.y + sin(angle) * r + fall)
                        let rect = CGRect(x: point.x - sparkSize / 2, y: point.y - sparkSize / 2,
                                          width: sparkSize, height: sparkSize)
                        context.fill(Path(ellipseIn: rect),
                                     with: .color(burst.color.opacity(opacity * fade)))
                    }
                }
            }
        }
    }
}

// MARK: - Birthday cake

/// A two-tier cake whose candles go out one tap at a time.
struct BirthdayCake: View {
    let lit: [Bool]
    /// Off under Reduce Motion: the flames hold still.
    let flickers: Bool
    let onBlow: (Int) -> Void

    private let sponge = Color(red: 1.0, green: 0.93, blue: 0.82)
    private let icing = Color(red: 1.0, green: 0.76, blue: 0.84)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(lit.indices, id: \.self) { index in
                    Candle(lit: lit[index], flickers: flickers, seed: Double(index))
                        .onTapGesture { onBlow(index) }
                        .accessibilityHidden(true)
                }
            }
            .zIndex(1)
            tier(width: 190, height: 58, fill: icing, band: Theme.accent.opacity(0.75))
            tier(width: 250, height: 70, fill: sponge, band: icing)
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: 290, height: 14)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .accessibilityElement()
        .accessibilityLabel("A birthday cake")
    }

    private func tier(width: CGFloat, height: CGFloat, fill: Color, band: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                // Icing drips along the top edge.
                HStack(spacing: 4) {
                    ForEach(0..<Int(width / 22), id: \.self) { index in
                        Capsule()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 18, height: index.isMultiple(of: 2) ? 16 : 10)
                    }
                }
                .offset(y: -3)
            }
            .overlay {
                Rectangle().fill(band).frame(height: 7).offset(y: height * 0.18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Candle: View {
    let lit: Bool
    let flickers: Bool
    let seed: Double

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                if lit {
                    TimelineView(.animation(paused: !flickers)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        flame
                            .scaleEffect(x: 1, y: flickers ? 1 + 0.10 * sin(t * 13 + seed * 2) : 1,
                                         anchor: .bottom)
                            .rotationEffect(.degrees(flickers ? 4 * sin(t * 7 + seed) : 0), anchor: .bottom)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.3, anchor: .bottom)))
                } else {
                    Smoke().transition(.opacity)
                }
            }
            .frame(width: 24, height: 30)
            Rectangle().fill(Color(white: 0.25)).frame(width: 2, height: 5)
            Capsule()
                .fill(LinearGradient(colors: [Theme.accentBright, Theme.accent],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 11, height: 46)
                .overlay {
                    VStack(spacing: 7) {
                        ForEach(0..<4, id: \.self) { _ in
                            Rectangle().fill(.white.opacity(0.85)).frame(height: 3).rotationEffect(.degrees(-25))
                        }
                    }
                    .clipShape(Capsule())
                }
        }
        // Wide enough to hit with a thumb.
        .frame(width: 44, height: 90)
        .contentShape(Rectangle())
    }

    private var flame: some View {
        Ellipse()
            .fill(RadialGradient(colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.3), Theme.warm],
                                 center: UnitPoint(x: 0.5, y: 0.7), startRadius: 1, endRadius: 14))
            .frame(width: 14, height: 24)
            .shadow(color: Color(red: 1.0, green: 0.75, blue: 0.3).opacity(0.8), radius: 8)
    }
}

/// A wisp that rises and fades once.
private struct Smoke: View {
    @State private var gone = false

    var body: some View {
        Circle()
            .fill(Color(white: 0.6).opacity(gone ? 0 : 0.5))
            .frame(width: gone ? 18 : 8, height: gone ? 18 : 8)
            .offset(y: gone ? -26 : 0)
            .onAppear { withAnimation(.easeOut(duration: 1.2)) { gone = true } }
    }
}

// MARK: - Scratch card

/// The words under a foil that a finger rubs away; past half of it, the rest goes.
struct ScratchCard: View {
    let text: String
    let opened: Bool
    let onOpen: () -> Void

    @State private var strokes: [[CGPoint]] = []
    @State private var scratching = false
    /// Which cells of a coarse grid the finger has passed over.
    @State private var touched: Set<Int> = []
    @State private var sinceTick = 0

    private static let columns = 10
    private static let rows = 6
    private static let brush: CGFloat = 46
    private static let openShare = 0.55

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                Text(text)
                    .font(Theme.rounded(30, .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(.primary)
                    .padding(22)
                    .accessibilityHidden(!opened)
                foil
                    .mask { mask(size: size) }
                    .opacity(opened ? 0 : 1)
                    .allowsHitTesting(!opened)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { scratch(at: $0.location, size: size) }
                .onEnded { _ in scratching = false })
        }
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
    }

    private var foil: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.74), Color(white: 0.93), Color(white: 0.70), Color(white: 0.86)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                VStack(spacing: 6) {
                    Text("✨ 🎁 ✨").font(.system(size: 26))
                    Text("Scratch here")
                        .font(Theme.rounded(18, .bold))
                        .foregroundStyle(Color(white: 0.3))
                }
            }
    }

    private func mask(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(.black))
            context.blendMode = .destinationOut
            for stroke in strokes {
                var path = Path()
                path.addLines(stroke.count == 1 ? [stroke[0], stroke[0] + CGPoint(x: 0.5, y: 0)] : stroke)
                context.stroke(path, with: .color(.black),
                               style: StrokeStyle(lineWidth: Self.brush, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func scratch(at point: CGPoint, size: CGSize) {
        guard !opened, size.width > 0, size.height > 0 else { return }
        // Judged along the whole segment the stroke draws, not just at the
        // samples: a fast swipe arrives as a few far-apart points.
        var samples = [point]
        if scratching, let last = strokes.last?.last {
            strokes[strokes.count - 1].append(point)
            let steps = max(1, Int(hypot(point.x - last.x, point.y - last.y) / 8))
            samples = (1...steps).map { step in
                let t = CGFloat(step) / CGFloat(steps)
                return CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t)
            }
        } else {
            strokes.append([point])
            scratching = true
        }
        let cell = CGSize(width: size.width / CGFloat(Self.columns), height: size.height / CGFloat(Self.rows))
        let before = touched.count
        for sample in samples {
            for row in 0..<Self.rows {
                for column in 0..<Self.columns {
                    let center = CGPoint(x: (CGFloat(column) + 0.5) * cell.width,
                                         y: (CGFloat(row) + 0.5) * cell.height)
                    if hypot(center.x - sample.x, center.y - sample.y) < Self.brush * 0.6 {
                        touched.insert(row * Self.columns + column)
                    }
                }
            }
        }
        sinceTick += touched.count - before
        if sinceTick >= 4 {
            sinceTick = 0
            UISelectionFeedbackGenerator().selectionChanged()
        }
        if Double(touched.count) >= Double(Self.columns * Self.rows) * Self.openShare {
            onOpen()
        }
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
}
