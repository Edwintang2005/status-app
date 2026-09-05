import SwiftUI

/// The easter egg, three layers deep: tie the fox and the fish together, hold
/// the logo they become, then the count.
struct EasterEggView: View {
    private enum Stage { case tying, logo, count }

    @State private var stage = Stage.tying

    var body: some View {
        ZStack {
            switch stage {
            case .tying:
                TieTheStringView { stage = .logo }
                    .transition(.opacity)
            case .logo:
                LogoView { stage = .count }
                    .transition(.opacity)
            case .count:
                AnniversaryView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.5), value: stage)
    }
}

/// The pair, become the logo, waiting. It breathes; holding it for a moment
/// opens the count. Laid out exactly where `TieTheStringView` left the logo
/// so the hand-off is a still frame, not a jump.
struct LogoView: View {
    let onReveal: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var pressing = false

    var body: some View {
        ZStack {
            Theme.Background()
            GeometryReader { geometry in
                let size = geometry.size
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(size.width * 0.8, 340))
                    .shadow(color: Theme.accent.opacity(pressing ? 0.55 : 0.3), radius: pressing ? 36 : 24, y: 10)
                    .scaleEffect((breathing && !reduceMotion ? 1.03 : 1) * (pressing ? 0.94 : 1))
                    .position(x: size.width / 2, y: size.height * 0.485)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.2, pressing: { down in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pressing = down }
                    }, perform: reveal)
            }
            .ignoresSafeArea(edges: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppConfig.appName)
            .accessibilityHint("Hold to open")
            .accessibilityAction(named: Text("Open"), reveal)

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(Theme.rounded(14, .bold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    private func reveal() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onReveal()
    }
}

/// The fox and the fish idle on either side; dragging from one to the other
/// draws the red string, and letting go on the far end ties it — they meet, a
/// heart pops, and the pair becomes the logo. A miss retracts the string; two
/// misses earn a hint.
struct TieTheStringView: View {
    let onTied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum End { case fox, fish }

    /// Which animal the string was picked up from, and where the finger is now.
    @State private var anchor: End?
    @State private var tip: CGPoint?
    @State private var tied = false
    @State private var misses = 0
    @State private var heartShown = false
    /// The payoff: the pair becomes the app's own mark before the count appears.
    @State private var logoShown = false

    private static let grabRadius: CGFloat = 70

    var body: some View {
        ZStack {
            Theme.Background()
            GeometryReader { geometry in
                TimelineView(.animation(paused: reduceMotion || tied)) { context in
                    canvas(in: geometry.size, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            // The river runs under the home indicator rather than stopping short.
            .ignoresSafeArea(edges: .bottom)
            // The scene is one element with a custom action; the puzzle isn't
            // asked of VoiceOver users. The Close button stays its own element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A fox and a fish")
            .accessibilityHint("Tie the red string between them")
            .accessibilityAction(named: Text("Tie the string")) { tie() }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(Theme.rounded(14, .bold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                Text("Tie them together")
                    .font(Theme.rounded(13, .medium))
                    .foregroundStyle(.tertiary)
                    .opacity(misses >= 2 && !tied ? 1 : 0)
                    .animation(.smooth(duration: 0.6), value: misses)
                    .padding(.bottom, 12)
            }
            .padding(20)
        }
    }

    // MARK: - Scene

    /// On the bank; when tied, down to the water's edge.
    private func foxCenter(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (tied ? 0.40 : 0.24), y: size.height * (tied ? 0.45 : 0.42))
    }

    /// In the river; when tied, up to the surface.
    private func fishCenter(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (tied ? 0.60 : 0.74), y: size.height * (tied ? 0.52 : 0.58))
    }

    private func canvas(in size: CGSize, time: TimeInterval) -> some View {
        let fox = foxCenter(size)
        let fish = fishCenter(size)
        // Idle bob and sway; frozen once tied so the knot sits still.
        let bob = tied ? 0 : sin(time * 2.1) * 6
        let sway = tied ? 0 : sin(time * 1.4) * 7
        let foxNow = CGPoint(x: fox.x, y: fox.y + bob)
        let fishNow = CGPoint(x: fish.x + sway, y: fish.y - bob * 0.6)
        let midpoint = CGPoint(x: (foxNow.x + fishNow.x) / 2, y: (foxNow.y + fishNow.y) / 2)

        return ZStack {
            RiverbankScene(time: time)

            if let from = stringStart(fox: foxNow, fish: fishNow),
               let to = stringEnd(fox: foxNow, fish: fishNow) {
                RedString(from: from, to: to)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 3)
            }

            Text("🦊")
                .font(.system(size: 76))
                .position(foxNow)
            Text("🐟")
                .font(.system(size: 72))
                .rotationEffect(.degrees(tied ? 0 : sway * 0.8))
                .position(fishNow)

            if tied {
                Text("❤️")
                    .font(.system(size: 34))
                    .scaleEffect(heartShown ? 1 : 0.2)
                    .opacity(heartShown ? 1 : 0)
                    .position(x: midpoint.x, y: midpoint.y + RedString.sag(from: foxNow, to: fishNow) * 0.75)
            }
        }
        .opacity(logoShown ? 0 : 1)
        .overlay {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: min(size.width * 0.8, 340))
                .shadow(color: Theme.accent.opacity(0.3), radius: 24, y: 10)
                .scaleEffect(logoShown ? 1 : 0.7)
                .opacity(logoShown ? 1 : 0)
                .position(midpoint)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(fox: fox, fish: fish))
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: tied)
    }

    private func stringStart(fox: CGPoint, fish: CGPoint) -> CGPoint? {
        if tied { return fox }
        switch anchor {
        case .fox: return fox
        case .fish: return fish
        case nil: return nil
        }
    }

    private func stringEnd(fox: CGPoint, fish: CGPoint) -> CGPoint? {
        tied ? fish : tip
    }

    // MARK: - Gesture

    private func dragGesture(fox: CGPoint, fish: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !tied else { return }
                if anchor == nil {
                    // Only a grab on one of them picks the string up.
                    if value.startLocation.distance(to: fox) < Self.grabRadius {
                        anchor = .fox
                    } else if value.startLocation.distance(to: fish) < Self.grabRadius {
                        anchor = .fish
                    } else {
                        return
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                tip = value.location
            }
            .onEnded { value in
                guard !tied, let anchor else { return }
                let target = anchor == .fox ? fish : fox
                if value.location.distance(to: target) < Self.grabRadius {
                    tie()
                } else {
                    misses += 1
                    // Retract: slide the tip home, then let go of it.
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        tip = anchor == .fox ? fox : fish
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !tied else { return }
                        self.anchor = nil
                        tip = nil
                    }
                }
            }
    }

    private func tie() {
        guard !tied else { return }
        tied = true
        anchor = nil
        tip = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.25)) {
            heartShown = true
        }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(1.1)) {
            logoShown = true
        }
        // Hands over once the logo has fully faded in, so `LogoView` picks up
        // the same still frame.
        Task {
            try? await Task.sleep(for: .milliseconds(2400))
            onTied()
        }
    }
}

/// The backdrop: a grassy bank on the left, the river on the right, a moon over
/// the water. One `Canvas`, redrawn per frame for the waves, shimmer, stars
/// and reeds; `time` stops moving under Reduce Motion or once tied.
private struct RiverbankScene: View {
    let time: TimeInterval

    @Environment(\.colorScheme) private var colorScheme

    private static let grass = Color(red: 0.56, green: 0.72, blue: 0.48)
    private static let grassDeep = Color(red: 0.40, green: 0.58, blue: 0.36)
    private static let moon = Color(red: 0.99, green: 0.96, blue: 0.86)
    private static let cattail = Color(red: 0.55, green: 0.33, blue: 0.22)

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let dark = colorScheme == .dark
            let waterline = h * 0.47

            // Moon and its glow.
            let moonAt = CGPoint(x: w * 0.78, y: h * 0.15)
            context.fill(Path(ellipseIn: CGRect(x: moonAt.x - 64, y: moonAt.y - 64, width: 128, height: 128)),
                         with: .radialGradient(Gradient(colors: [Theme.warm.opacity(dark ? 0.35 : 0.30), .clear]),
                                               center: moonAt, startRadius: 0, endRadius: 64))
            context.fill(Path(ellipseIn: CGRect(x: moonAt.x - 24, y: moonAt.y - 24, width: 48, height: 48)),
                         with: .color(Self.moon.opacity(dark ? 0.95 : 0.9)))

            // Stars, each on its own twinkle.
            let stars: [(CGFloat, CGFloat, Double)] = [(0.12, 0.10, 0), (0.30, 0.18, 1.3), (0.52, 0.09, 2.1),
                                                       (0.66, 0.22, 0.7), (0.90, 0.28, 2.8), (0.42, 0.26, 1.9),
                                                       (0.20, 0.30, 3.4)]
            for (fx, fy, phase) in stars {
                let twinkle = 0.45 + 0.4 * sin(time * 1.7 + phase)
                let r: CGFloat = 1.6
                context.fill(Path(ellipseIn: CGRect(x: w * fx - r, y: h * fy - r, width: r * 2, height: r * 2)),
                             with: .color(Self.moon.opacity(twinkle * (dark ? 1 : 0.8))))
            }

            // Distant hills, clipped at the waterline so they stop at the far shore.
            context.drawLayer { hills in
                hills.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: waterline)))
                hills.fill(Path(ellipseIn: CGRect(x: -w * 0.30, y: h * 0.39, width: w * 1.0, height: h * 0.22)),
                           with: .color(Self.grassDeep.opacity(dark ? 0.35 : 0.30)))
                hills.fill(Path(ellipseIn: CGRect(x: w * 0.45, y: h * 0.41, width: w * 0.9, height: h * 0.18)),
                           with: .color(Theme.mint.opacity(dark ? 0.30 : 0.28)))
            }

            // The bank's outline, needed first: waves and shimmer clip to the water alone.
            var bank = Path()
            bank.move(to: CGPoint(x: 0, y: h * 0.46))
            bank.addCurve(to: CGPoint(x: w * 0.42, y: h * 0.46),
                          control1: CGPoint(x: w * 0.15, y: h * 0.42),
                          control2: CGPoint(x: w * 0.30, y: h * 0.42))
            bank.addCurve(to: CGPoint(x: w * 0.34, y: h),
                          control1: CGPoint(x: w * 0.54, y: h * 0.52),
                          control2: CGPoint(x: w * 0.40, y: h * 0.76))
            bank.addLine(to: CGPoint(x: 0, y: h))
            bank.closeSubpath()

            // The river: full width below the waterline, the bank drawn over it.
            let water = Path(CGRect(x: 0, y: waterline, width: w, height: h - waterline))
            context.fill(water, with: .linearGradient(
                Gradient(colors: [Theme.mint.opacity(dark ? 0.55 : 0.60), Theme.mint.opacity(dark ? 0.30 : 0.35)]),
                startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: h)))

            // Waves and shimmer, clipped to the water minus the bank (even-odd
            // of the two outlines) and scoped to a layer so the clip ends here.
            context.drawLayer { surface in
                var openWater = water
                openWater.addPath(bank)
                surface.clip(to: openWater, style: FillStyle(eoFill: true))

                // Waves drift right; each row at its own pace.
                for (index, fy) in [0.505, 0.56, 0.625, 0.70].enumerated() {
                    var wave = Path()
                    let y = h * fy
                    let amplitude: CGFloat = 2.5 + CGFloat(index)
                    let wavelength: CGFloat = 70 + CGFloat(index) * 18
                    let drift = time * (18 + Double(index) * 6)
                    wave.move(to: CGPoint(x: 0, y: y))
                    for x in stride(from: 0, through: w, by: 4) {
                        let phase = (Double(x) - drift) / wavelength * 2 * .pi
                        wave.addLine(to: CGPoint(x: x, y: y + sin(phase) * amplitude))
                    }
                    surface.stroke(wave, with: .color(.white.opacity(dark ? 0.16 : 0.35)),
                                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }

                // Moonlight on the water: a column of short dashes that shimmer.
                for step in 0..<9 {
                    let y = waterline + 14 + CGFloat(step) * 22
                    let shimmer = 0.5 + 0.5 * sin(time * 2.3 + Double(step) * 1.1)
                    let width = 14 + CGFloat(shimmer) * 18
                    surface.fill(Path(roundedRect: CGRect(x: moonAt.x - width / 2 + sin(time + Double(step)) * 4,
                                                          y: y, width: width, height: 3), cornerRadius: 1.5),
                                 with: .color(Self.moon.opacity((0.25 + 0.35 * shimmer) * (dark ? 0.8 : 0.9))))
                }
            }

            // The bank: a rounded shore from the left edge down to the bottom.
            context.fill(bank, with: .linearGradient(
                Gradient(colors: [Self.grass.opacity(dark ? 0.92 : 0.97), Self.grassDeep.opacity(dark ? 0.9 : 0.92)]),
                startPoint: CGPoint(x: 0, y: h * 0.42), endPoint: CGPoint(x: 0, y: h)))
            context.stroke(bank, with: .color(Self.moon.opacity(dark ? 0.15 : 0.45)), lineWidth: 1.5)

            // Grass tufts and a few flowers so the bank reads as meadow, not paint.
            let tufts: [(CGFloat, CGFloat, Double)] = [(0.08, 0.55, 0.4), (0.20, 0.62, 1.7), (0.05, 0.74, 2.6),
                                                       (0.27, 0.72, 0.9), (0.14, 0.85, 2.0), (0.30, 0.90, 3.1),
                                                       (0.22, 0.51, 1.2)]
            for (fx, fy, phase) in tufts {
                let base = CGPoint(x: w * fx, y: h * fy)
                let lean = sin(time * 1.5 + phase) * 1.5
                for blade in -1...1 {
                    var path = Path()
                    path.move(to: base)
                    path.addQuadCurve(to: CGPoint(x: base.x + CGFloat(blade) * 6 + lean, y: base.y - 14),
                                      control: CGPoint(x: base.x + CGFloat(blade) * 2, y: base.y - 8))
                    context.stroke(path, with: .color(Self.grassDeep.opacity(dark ? 0.9 : 1)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            let flowers: [(CGFloat, CGFloat, Color)] = [(0.12, 0.66, Self.moon), (0.25, 0.80, Theme.accentBright),
                                                        (0.06, 0.93, Self.moon), (0.31, 0.58, Theme.warm),
                                                        (0.17, 0.95, Theme.accentBright)]
            for (fx, fy, color) in flowers {
                let at = CGPoint(x: w * fx, y: h * fy)
                for petal in 0..<5 {
                    let angle = Double(petal) / 5 * 2 * .pi
                    context.fill(Path(ellipseIn: CGRect(x: at.x + cos(angle) * 3 - 2, y: at.y + sin(angle) * 3 - 2,
                                                        width: 4, height: 4)),
                                 with: .color(color.opacity(0.9)))
                }
                context.fill(Path(ellipseIn: CGRect(x: at.x - 1.5, y: at.y - 1.5, width: 3, height: 3)),
                             with: .color(Theme.warm))
            }

            // Reeds at the shore, swaying from the tip.
            let reeds: [(CGFloat, CGFloat, CGFloat, Double)] = [(0.37, 0.49, 46, 0), (0.40, 0.52, 38, 1.1),
                                                                (0.43, 0.56, 52, 2.3), (0.46, 0.60, 34, 0.6),
                                                                (0.41, 0.63, 44, 1.8)]
            for (fx, fy, height, phase) in reeds {
                let base = CGPoint(x: w * fx, y: h * fy)
                let lean = sin(time * 1.3 + phase) * 4
                let tip = CGPoint(x: base.x + lean, y: base.y - height)
                var reed = Path()
                reed.move(to: base)
                reed.addQuadCurve(to: tip, control: CGPoint(x: base.x + lean * 0.3, y: base.y - height * 0.55))
                context.stroke(reed, with: .color(Self.grassDeep), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(Path(roundedRect: CGRect(x: tip.x - 2.5, y: tip.y - 2, width: 5, height: 13),
                                  cornerRadius: 2.5),
                             with: .color(Self.cattail))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A slack piece of string between two points: a quadratic curve sagging
/// under its own length. Animatable at both ends so retraction slides home.
private struct RedString: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    static func sag(from: CGPoint, to: CGPoint) -> CGFloat {
        min(from.distance(to: to) * 0.28, 70)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let control = CGPoint(x: (from.x + to.x) / 2,
                              y: (from.y + to.y) / 2 + Self.sag(from: from, to: to))
        path.addQuadCurve(to: to, control: control)
        return path
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

#if DEBUG
#Preview("Tie the string") {
    TieTheStringView {}
}
#endif
