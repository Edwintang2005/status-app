import SwiftUI

/// The easter egg: tie the fox and the fish together and the count opens, the
/// logo they become rising into its header.
struct EasterEggView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Namespace private var logo
    @State private var tied = false

    var body: some View {
        // Reduce Motion and VoiceOver take the plain path: no flight, a crossfade.
        let plain = reduceMotion || voiceOver
        ZStack {
            if tied {
                AnniversaryView(logo: plain ? nil : logo)
                    .transition(.opacity)
            } else {
                TieTheStringView(logo: plain ? nil : logo) { tied = true }
                    .transition(.opacity)
            }
        }
        .animation(plain ? .easeInOut(duration: 0.3) : .smooth(duration: 0.6), value: tied)
    }
}

extension View {
    /// The logo's one identity across the tie and the count, so it flies from
    /// the knot into the header; `nil` on the plain path.
    @ViewBuilder
    func matchedLogo(_ namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: "logo", in: namespace)
        } else {
            self
        }
    }
}

/// The close button every stage of the egg shares: a full 44 pt target.
struct EggCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(Theme.rounded(14, .bold))
                .foregroundStyle(Theme.mutedText)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Close")
    }
}

/// The fox and the fish idle on either side; dragging from one to the other
/// draws the red string — or tap one, then the other — and letting go on the
/// far end ties it: they meet, a heart pops, and the pair becomes the logo.
/// A miss retracts the string.
struct TieTheStringView: View {
    let logo: Namespace.ID?
    let onTied: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum End { case fox, fish }

    /// Which animal the string was picked up from, and where the finger is now.
    @State private var anchor: End?
    @State private var tip: CGPoint?
    /// Tapped once: the string waits on this animal for a tap on the other.
    @State private var armed: End?
    @State private var tied = false
    @State private var handedOff = false
    @State private var hintShown = false
    @State private var heartShown = false
    /// The payoff: the pair becomes the app's own mark before the count appears.
    @State private var logoShown = false

    private static let grabRadius: CGFloat = 70
    /// Under this much travel a touch is a tap, not a drag.
    private static let tapSlop: CGFloat = 10

    var body: some View {
        ZStack {
            Theme.Background()
            GeometryReader { geometry in
                scene(in: geometry.size)
            }
            // The river runs under the home indicator rather than stopping short.
            .ignoresSafeArea(edges: .bottom)
            // One element whose double-tap ties; the puzzle isn't asked of
            // VoiceOver users. The Close button stays its own element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A fox and a fish")
            .accessibilityHint("Double-tap to tie the red string")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tie() }
            .accessibilityAction(named: Text("Tie the string")) { tie() }

            VStack {
                HStack {
                    Spacer()
                    EggCloseButton()
                }
                Spacer()
                Text(hintText)
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity((hintShown || armed != nil) && !tied ? 1 : 0)
                    .animation(.smooth(duration: 0.6), value: hintShown)
                    .accessibilityHidden(true)
                    .padding(.bottom, 12)
            }
            .padding(16)
        }
        // A first visit shows the hint after a few idle seconds; a repeat
        // visitor ties before it ever appears.
        .task {
            try? await Task.sleep(for: .seconds(3))
            hintShown = true
        }
    }

    private var hintText: LocalizedStringKey {
        switch armed {
        case .fox: "Now tap the fish"
        case .fish: "Now tap the fox"
        case nil: "Drag the red string from the fox to the fish"
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

    /// Only the drawing ticks per frame; the gesture, the logo and the tie's
    /// animation sit outside the timeline.
    private func scene(in size: CGSize) -> some View {
        let fox = foxCenter(size)
        let fish = fishCenter(size)
        // Tied, nothing bobs: the knot's point is fixed.
        let midpoint = CGPoint(x: (fox.x + fish.x) / 2, y: (fox.y + fish.y) / 2)

        return TimelineView(.animation(paused: reduceMotion || tied)) { context in
            drawing(fox: fox, fish: fish, time: context.date.timeIntervalSinceReferenceDate)
        }
        .opacity(logoShown ? 0 : 1)
        .overlay {
            if logoShown {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(size.width * 0.8, 340))
                    .matchedLogo(logo)
                    .shadow(color: Theme.accent.opacity(0.3), radius: 24, y: 10)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .position(midpoint)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(fox: fox, fish: fish))
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7), value: tied)
    }

    private func drawing(fox: CGPoint, fish: CGPoint, time: TimeInterval) -> some View {
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
            } else if !tied {
                // At rest a slack tail hangs from the fox: the gesture, without words.
                RedString(from: CGPoint(x: foxNow.x + 22, y: foxNow.y + 24),
                          to: CGPoint(x: foxNow.x + 48, y: foxNow.y + 62))
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
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
                    .scaleEffect(heartShown || reduceMotion ? 1 : 0.2)
                    .opacity(heartShown ? 1 : 0)
                    .position(x: midpoint.x, y: midpoint.y + RedString.sag(from: foxNow, to: fishNow) * 0.75)
            }
        }
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
        func center(_ end: End) -> CGPoint { end == .fox ? fox : fish }
        func other(_ end: End) -> End { end == .fox ? .fish : .fox }

        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !tied else { return }
                if let armed {
                    // Waiting for the second tap: only a touch on the armed
                    // animal picks the string back up to drag.
                    guard value.startLocation.distance(to: center(armed)) < Self.grabRadius else { return }
                    self.armed = nil
                }
                if anchor == nil {
                    // Only a grab on one of them picks the string up.
                    if value.startLocation.distance(to: fox) < Self.grabRadius {
                        anchor = .fox
                    } else if value.startLocation.distance(to: fish) < Self.grabRadius {
                        anchor = .fish
                    } else {
                        hintShown = true
                        return
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                tip = value.location
            }
            .onEnded { value in
                if tied {
                    handOff()
                    return
                }
                let isTap = abs(value.translation.width) < Self.tapSlop && abs(value.translation.height) < Self.tapSlop
                if let armed {
                    if isTap, value.startLocation.distance(to: center(other(armed))) < Self.grabRadius {
                        tie()
                    } else {
                        retract(to: center(armed))
                    }
                    return
                }
                guard let anchor else { return }
                if value.location.distance(to: center(other(anchor))) < Self.grabRadius {
                    tie()
                } else if isTap {
                    arm(anchor, from: center(anchor), toward: center(other(anchor)))
                } else {
                    hintShown = true
                    retract(to: center(anchor))
                }
            }
    }

    /// A tap on one animal: the string drifts toward the other and waits.
    private func arm(_ end: End, from: CGPoint, toward: CGPoint) {
        armed = end
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            tip = CGPoint(x: from.x + (toward.x - from.x) * 0.55, y: from.y + (toward.y - from.y) * 0.55 + 30)
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard armed == end, !tied else { return }
            retract(to: from)
        }
    }

    /// Slide the tip home, then let go of it.
    private func retract(to home: CGPoint) {
        armed = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            tip = home
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !tied, armed == nil else { return }
            anchor = nil
            tip = nil
        }
    }

    private func tie() {
        guard !tied else { return }
        tied = true
        anchor = nil
        armed = nil
        tip = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if reduceMotion || logo == nil {
            // The plain path: the heart fades in and the count crossfades.
            withAnimation(.easeIn(duration: 0.2)) { heartShown = true }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                handOff()
            }
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.25)) {
            heartShown = true
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.6)) {
            logoShown = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            handOff()
        }
    }

    /// Once only: the timer, or a tap that skips the rest of the animation.
    private func handOff() {
        guard tied, !handedOff else { return }
        handedOff = true
        onTied()
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
    TieTheStringView(logo: nil) {}
}
#endif
