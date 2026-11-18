import SwiftUI

// The two celebrations that ask for a gesture before the words: the cake and
// the scratch card. `CelebrationOverlay` stages them.

// MARK: - Birthday cake

enum CandleState: Equatable {
    /// Not lit yet: the candles light one by one as the cake arrives.
    case unlit
    case lit
    /// Blown out; the flame leans away from the breath (−1 left, 1 right).
    case out(lean: Double)
}

/// A two-tier cake whose candles go out one tap at a time.
struct BirthdayCake: View {
    let candles: [CandleState]
    /// Off under Reduce Motion: the flames hold still and nothing flares.
    let flickers: Bool
    /// The candle, and which way its flame should lean.
    let onBlow: (Int, Double) -> Void

    private let sponge = Color(red: 1.0, green: 0.93, blue: 0.82)
    private let icing = Color(red: 1.0, green: 0.76, blue: 0.84)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(candles.indices, id: \.self) { index in
                    Candle(state: candles[index], flickers: flickers, seed: Double(index))
                        // Leans away from the side the tap came from.
                        .onTapGesture(coordinateSpace: .local) { location in
                            onBlow(index, location.x < Candle.width / 2 ? 1 : -1)
                        }
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
    let state: CandleState
    let flickers: Bool
    let seed: Double

    static let width: CGFloat = 44

    @State private var flare = 0.0

    private var lean: Double {
        if case .out(let lean) = state { lean } else { 0 }
    }

    private var isOut: Bool {
        if case .out = state { true } else { false }
    }

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                flame
                if isOut { Smoke(still: !flickers) }
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
        .frame(width: Self.width, height: 90)
        .contentShape(Rectangle())
        .onChange(of: state) { old, new in
            guard old == .unlit, new == .lit, flickers else { return }
            flare = 1
            withAnimation(.easeOut(duration: 0.5)) { flare = 0 }
        }
    }

    /// Always in the tree, so lighting and blowing out animate its shape.
    private var flame: some View {
        let live = flickers && state == .lit
        return TimelineView(.animation(paused: !live)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Ellipse()
                .fill(RadialGradient(colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.3), Theme.warm],
                                     center: UnitPoint(x: 0.5, y: 0.7), startRadius: 1, endRadius: 14))
                .frame(width: 14, height: 24)
                .shadow(color: Color(red: 1.0, green: 0.75, blue: 0.3).opacity(0.8), radius: 8)
                .scaleEffect(x: 1, y: live ? 1 + 0.10 * sin(t * 13 + seed * 2) : 1, anchor: .bottom)
                .rotationEffect(.degrees(live ? 4 * sin(t * 7 + seed) : 0), anchor: .bottom)
        }
        .background {
            Circle()
                .fill(Color(red: 1.0, green: 0.85, blue: 0.45))
                .frame(width: 34, height: 34)
                .blur(radius: 7)
                .opacity(flare * 0.9)
        }
        .scaleEffect(state == .lit ? 1 : 0.18, anchor: .bottom)
        .rotationEffect(.degrees(lean * 30), anchor: .bottom)
        .opacity(state == .lit ? 1 : 0)
    }
}

/// Three puffs that curl up and fade once.
private struct Smoke: View {
    let still: Bool

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Puff(delay: Double(index) * 0.18, drift: [4, -5, 6][index], still: still)
            }
        }
    }
}

private struct Puff: View {
    let delay: Double
    let drift: CGFloat
    let still: Bool

    @State private var rising = false
    @State private var curl = false

    var body: some View {
        Circle()
            .fill(Color(white: 0.5))
            .frame(width: 9, height: 9)
            .scaleEffect(rising ? (still ? 1.3 : 2.3) : 0.6)
            .offset(x: still ? 0 : (curl ? drift : -drift / 2), y: rising && !still ? -46 : 0)
            .opacity(rising ? 0 : 0.6)
            .onAppear {
                withAnimation(.easeOut(duration: 1.5).delay(delay)) { rising = true }
                guard !still else { return }
                withAnimation(.easeInOut(duration: 0.4).delay(delay).repeatCount(3, autoreverses: true)) { curl = true }
            }
    }
}

// MARK: - Scratch card

/// The words under a foil that a finger rubs away; past half of it, the rest
/// breaks off and falls.
struct ScratchCard: View {
    let text: String
    let opened: Bool
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var strokes: [[CGPoint]] = []
    @State private var scratching = false
    /// Which cells of a coarse grid the finger has passed over.
    @State private var touched: Set<Int> = []
    @State private var sinceTick = 0
    @State private var shards: [FoilShard] = []

    static let columns = 10
    static let rows = 6
    private static let brush: CGFloat = 46
    private static let openShare = 0.55
    static let corner: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                Text(text)
                    .font(Theme.rounded(30, .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(.primary)
                    .padding(22)
                    .scaleEffect(opened ? 1 : 0.96)
                    .accessibilityHidden(!opened)
                    .accessibilityIdentifier("celebration.sealed")
                foil
                    .mask { mask(size: size) }
                    .opacity(opened ? 0 : 1)
                    // The shards take over at once; under Reduce Motion the foil fades.
                    .animation(reduceMotion ? .easeIn(duration: 0.3) : nil, value: opened)
                    .allowsHitTesting(!opened)
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { scratch(at: $0.location, size: size) }
                .onEnded { _ in scratching = false })
            .overlay(alignment: .top) {
                if !shards.isEmpty {
                    FoilShards(shards: shards, card: size)
                        .frame(width: size.width, height: size.height + FoilShards.fallRoom, alignment: .top)
                }
            }
            .onChange(of: opened) { _, now in
                guard now, !reduceMotion else { return }
                let left = (0..<(Self.columns * Self.rows)).filter { !touched.contains($0) }
                shards = FoilShard.breaking(cells: left)
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
    }

    private var foil: some View {
        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            .fill(LinearGradient(colors: FoilShard.foilStops.map { Color(white: $0) },
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                VStack(spacing: 6) {
                    Text("✨ 🎁 ✨").font(.system(size: 26))
                    Text("Scratch here")
                        .font(Theme.rounded(18, .bold))
                        .foregroundStyle(Color(white: 0.3))
                }
            }
            .overlay {
                // Invites the finger until it arrives.
                if !reduceMotion && strokes.isEmpty && !opened { Shimmer() }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
    }

    private func mask(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(.black))
            context.blendMode = .destinationOut
            for stroke in strokes {
                var path = Path()
                path.addLines(stroke.count == 1 ? [stroke[0], CGPoint(x: stroke[0].x + 0.5, y: stroke[0].y)] : stroke)
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

/// A slow band of light across the foil, once every three seconds.
private struct Shimmer: View {
    private static let period = 3.0
    private static let sweep = 1.1

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
                let p = min(1, t / Self.sweep)
                let eased = p * p * (3 - 2 * p)
                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70, height: size.height * 1.8)
                    .rotationEffect(.degrees(20))
                    .position(x: -60 + (size.width + 120) * eased, y: size.height / 2)
                    .opacity(t < Self.sweep ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One cell of foil left on the card when it opens.
struct FoilShard {
    let cell: Int
    let velocity: CGVector
    let spin: Double
    let delay: Double

    /// The foil gradient's greys, top-leading to bottom-trailing.
    static let foilStops = [0.74, 0.93, 0.70, 0.86]

    static func breaking(cells: [Int]) -> [FoilShard] {
        cells.map { cell in
            FoilShard(cell: cell,
                      velocity: CGVector(dx: .random(in: -70...70), dy: .random(in: -170...(-30))),
                      spin: .random(in: -4...4), delay: .random(in: 0..<0.12))
        }
    }

    /// The foil's grey at a point along its diagonal, 0…1.
    static func grey(at position: Double) -> Double {
        let scaled = min(max(position, 0), 1) * Double(foilStops.count - 1)
        let low = Int(scaled), high = min(low + 1, foilStops.count - 1)
        return foilStops[low] + (foilStops[high] - foilStops[low]) * (scaled - Double(low))
    }
}

/// The rest of the foil, falling away.
private struct FoilShards: View {
    let shards: [FoilShard]
    let card: CGSize

    static let fallRoom: CGFloat = 520
    private static let gravity = 1500.0
    private static let life = 0.9

    var body: some View {
        ParticleClock(lasts: Self.life + 0.2) { elapsed in
            Canvas { context, _ in
                let cell = CGSize(width: card.width / CGFloat(ScratchCard.columns),
                                  height: card.height / CGFloat(ScratchCard.rows))
                for shard in shards {
                    let t = max(0, elapsed - shard.delay)
                    let column = shard.cell % ScratchCard.columns, row = shard.cell / ScratchCard.columns
                    let x = (CGFloat(column) + 0.5) * cell.width + shard.velocity.dx * t
                    let y = (CGFloat(row) + 0.5) * cell.height + shard.velocity.dy * t + 0.5 * Self.gravity * t * t
                    let along = (Double(column) / Double(ScratchCard.columns) + Double(row) / Double(ScratchCard.rows)) / 2
                    context.drawLayer { layer in
                        layer.opacity = max(0, 1 - t / Self.life)
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(shard.spin * t))
                        let rect = CGRect(x: -cell.width / 2, y: -cell.height / 2, width: cell.width, height: cell.height)
                        let path = Path(roundedRect: rect, cornerRadius: 3)
                        layer.fill(path, with: .color(Color(white: FoilShard.grey(at: along))))
                        layer.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.8)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
