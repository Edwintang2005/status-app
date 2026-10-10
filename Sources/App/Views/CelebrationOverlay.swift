import SwiftUI

/// Shown on first open after a celebration status arrives — see
/// `Snapshot.pendingCelebration` and `AppModel.celebrationPlayed()`. One shell
/// for every `CelebrationStyle`: the backdrop, particles and opening differ;
/// the words, the heart back and Report… are shared.
struct CelebrationOverlay: View {
    let payload: StatusPayload
    let partnerName: String
    let onDismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// The candles are out, or the surprise scratched open: the words follow.
    @State private var opened = false
    @State private var candles = [true, true, true]
    /// Fixed at init so the particles don't reshuffle on every redraw.
    @State private var pieces = ConfettiPiece.emitter()
    @State private var goldPieces = ConfettiPiece.emitter(colors: ConfettiPiece.gold,
                                                          glyphCount: ConfettiPiece.goldGlyphs.count)
    @State private var hearts = DriftPiece.hearts()
    @State private var snow = DriftPiece.snow()
    @State private var bursts = FireworkBurst.show()
    @State private var start = Date()
    @State private var confirmingReport = false

    private var style: CelebrationStyle { payload.celebration ?? .confetti }
    /// Birthday and reveal ask for a gesture before the words.
    private var interactive: Bool { style == .birthday || style == .reveal }
    private var showsWords: Bool { !interactive || opened }
    private var isNight: Bool { style == .fireworks || style == .snow }

    /// Their status as it may be shown; this fills the screen (invariant 20).
    private var shown: ModeratedStatus {
        payload.moderation(reportedAt: model.hiddenPartnerStatusAt, filterEnabled: model.contentFilterEnabled)
    }

    /// Their words, or the style's own line if they sent none — or the words
    /// can't be shown.
    private var headline: String {
        let message = shown.message
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !message.isPlaceholder else { return style.defaultHeadline }
        return trimmed
    }

    private var accessibilityText: String {
        switch style {
        case .birthday where !opened:
            String(localized: "\(partnerName) sent you a birthday cake. Make a wish, then blow out the candles.")
        case .reveal where !opened:
            String(localized: "\(partnerName) has a surprise for you.")
        default:
            String(localized: "\(headline). From \(partnerName).")
        }
    }

    var body: some View {
        ZStack {
            backdrop
            if !reduceMotion { particles.allowsHitTesting(false) }
            content
        }
        .ignoresSafeArea()
        // Night skies carry white text whatever the phone's appearance — and
        // drop the status bar, whose dark clock would vanish into them.
        .environment(\.colorScheme, isNight ? .dark : colorScheme)
        .statusBarHidden(isNight)
        // Whole screen dismisses once there's nothing left to do on it;
        // nothing underneath is tappable by accident.
        .contentShape(Rectangle())
        .onTapGesture { if showsWords { finish() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isModal)
        .accessibilityActions {
            if interactive, !opened {
                Button(style == .birthday ? "Blow out the candles" : "Reveal", action: blowOutAll)
            }
        }
        .accessibilityAction(named: "Dismiss", finish)
        .accessibilityAction(named: "Send a heart back") {
            Task {
                await model.sendNudge()
                finish()
            }
        }
        // Guideline 1.2: their words fill the screen, so they can be reported from here.
        .accessibilityAction(named: "Report…") { confirmingReport = true }
        .confirmationDialog("Report this status?",
                            isPresented: $confirmingReport,
                            titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                model.reportPartnerStatus()
                finish()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its text is hidden on this iPhone straight away, and the details go to us by email. We act on reports within 24 hours.")
        }
        .task {
            start = .now
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(reduceMotion ? .easeIn(duration: 0.4) : .spring(response: 0.7, dampingFraction: 0.6)) { revealed = true }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Layers

    /// Material, not opaque: the home screen faintly showing through makes this
    /// read as landing *on* the app, not another screen. Night styles darken it.
    private var backdrop: some View {
        let glows = style.glows
        return ZStack {
            Rectangle().fill(.regularMaterial)
            if isNight {
                LinearGradient(colors: style == .snow
                                   ? [Color(red: 0.06, green: 0.12, blue: 0.26), Color(red: 0.16, green: 0.22, blue: 0.38)]
                                   : [Color(red: 0.04, green: 0.04, blue: 0.13), Color(red: 0.14, green: 0.07, blue: 0.24)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.9)
            }
            RadialGradient(colors: [glows.0.opacity(0.55), .clear],
                           center: .center,
                           startRadius: 0,
                           endRadius: 420)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.2)
                .opacity(revealed ? 1 : 0)
            RadialGradient(colors: [glows.1.opacity(0.40), .clear],
                           center: UnitPoint(x: 0.5, y: 0.72),
                           startRadius: 0,
                           endRadius: 360)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.2)
                .opacity(revealed ? 1 : 0)
        }
    }

    @ViewBuilder
    private var particles: some View {
        switch style {
        case .confetti:
            ConfettiLayer(pieces: pieces, start: start)
        case .trophy:
            ConfettiLayer(pieces: goldPieces, start: start, glyphs: ConfettiPiece.goldGlyphs)
        case .hearts:
            DriftLayer(pieces: hearts, glyphs: DriftPiece.heartGlyphs, rising: true, start: start)
        case .snow:
            DriftLayer(pieces: snow, glyphs: DriftPiece.snowGlyphs, rising: false, start: start)
        case .fireworks:
            FireworksLayer(bursts: bursts, start: start)
        case .birthday, .reveal:
            // Inserted when opened, so its cycles count from then.
            if opened { ConfettiLayer(pieces: pieces, start: start) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch style {
            case .birthday:
                BirthdayCake(lit: candles, flickers: !reduceMotion, onBlow: blow)
                    .scaleEffect(revealed || reduceMotion ? 1 : 0.85)
                    .opacity(revealed ? 1 : 0)
                    .padding(.bottom, 28)
                if !opened {
                    prompt("Make a wish, then tap the candles to blow them out")
                }
            case .reveal:
                revealCard
            default:
                emoji
            }

            if showsWords, style != .reveal {
                words
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(.vertical, 64)
    }

    private var emoji: some View {
        Text(shown.emoji)
            .font(.system(size: 84))
            // The trophy drops in; the rest pop. Under Reduce Motion everything only fades.
            .offset(y: style == .trophy && !(revealed || reduceMotion) ? -420 : 0)
            .scaleEffect(style == .trophy || revealed || reduceMotion ? 1 : 0.3)
            .rotationEffect(.degrees(style == .trophy || revealed || reduceMotion ? 0 : -25))
            .opacity(revealed ? 1 : 0)
            .padding(.bottom, 26)
    }

    private var words: some View {
        VStack(spacing: 18) {
            // Sized to fit rather than truncated — anniversary messages run long.
            Text(headline)
                .font(Theme.rounded(style == .birthday ? 38 : 44, .bold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.45)
                .foregroundStyle(.primary)
                .shadow(color: style.glows.0.opacity(0.35), radius: 18)
                .padding(.horizontal, 34)
            from
        }
        .scaleEffect(revealed || reduceMotion ? 1 : 0.8)
        .opacity(revealed ? 1 : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var from: some View {
        Text("from \(partnerName)")
            .font(Theme.rounded(17, .medium))
            .foregroundStyle(Theme.mutedText)
    }

    /// Their news under foil until scratched (or "Just show me").
    private var revealCard: some View {
        VStack(spacing: 16) {
            if opened {
                Text(shown.emoji)
                    .font(.system(size: 64))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("Guess what…")
                    .font(Theme.rounded(34, .bold))
                    .multilineTextAlignment(.center)
            }
            ScratchCard(text: headline, opened: opened, onOpen: open)
                .frame(maxWidth: 340)
                .frame(height: 190)
                .padding(.horizontal, 28)
            if opened {
                from
            } else {
                prompt("Scratch the card to see what \(partnerName) has to tell you")
                Button("Just show me") { open() }
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .opacity(revealed ? 1 : 0)
    }

    private func prompt(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.rounded(16, .medium))
            .foregroundStyle(Theme.mutedText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var footer: some View {
        if showsWords {
            // The natural answer to their moment: the heart, then out.
            HeartBackButton(afterSending: finish)
                .padding(.horizontal, 44)
                .opacity(revealed ? 1 : 0)
                // Delayed until the words have landed.
                .animation(.smooth(duration: 0.4).delay(0.7), value: revealed)

            Text("Tap anywhere to close")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
                .padding(.top, 12)
                .opacity(revealed ? 1 : 0)
                .animation(.smooth(duration: 0.4).delay(1.1), value: revealed)
        } else {
            Button("Not now") { finish() }
                .font(Theme.rounded(15, .medium))
                .foregroundStyle(Theme.mutedText)
                .frame(minWidth: 44, minHeight: 44)
        }

        Button("Report...") { confirmingReport = true }
            .font(Theme.rounded(13, .medium))
            .foregroundStyle(Theme.mutedText)
            .frame(minWidth: 44, minHeight: 44)
            .opacity(revealed ? 1 : 0)
            .animation(.smooth(duration: 0.4).delay(1.1), value: revealed)
    }

    // MARK: - Opening

    private func blow(_ index: Int) {
        guard candles.indices.contains(index), candles[index] else { return }
        withAnimation(.easeOut(duration: 0.3)) { candles[index] = false }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !candles.contains(true) {
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                open()
            }
        }
    }

    /// VoiceOver's action: one breath for every candle, or the foil in one go.
    private func blowOutAll() {
        guard style == .birthday else { return open() }
        withAnimation(.easeOut(duration: 0.3)) { candles = candles.map { _ in false } }
        open()
    }

    private func open() {
        guard !opened else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(response: 0.6, dampingFraction: 0.7)) {
            opened = true
        }
        AccessibilityNotification.Announcement(String(localized: "\(headline). From \(partnerName).")).post()
    }

    private func finish() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onDismiss()
    }
}

private extension CelebrationStyle {
    /// The backdrop's two glows.
    var glows: (Color, Color) {
        switch self {
        case .confetti: (Theme.warm, Theme.accent)
        case .hearts: (Theme.accentBright, Theme.accent)
        case .trophy: (Color(red: 1.0, green: 0.80, blue: 0.35), Theme.warm)
        case .birthday: (Color(red: 1.0, green: 0.70, blue: 0.80), Theme.warm)
        case .reveal: (Theme.mint, Theme.accent)
        case .fireworks: (Color(red: 0.55, green: 0.35, blue: 0.95), Theme.accentBright)
        // Deep blues: a bright glow washed out the muted "from" line.
        case .snow: (Color(red: 0.32, green: 0.48, blue: 0.80), Color(red: 0.22, green: 0.32, blue: 0.58))
        }
    }
}

// MARK: - Confetti

/// One piece of confetti on a ballistic arc. Position is a pure function of
/// elapsed time, so the whole layer is one `Canvas` in a `TimelineView`.
struct ConfettiPiece: Identifiable {
    let id = UUID()
    /// Launch direction in radians, and speed in points per second.
    let angle: Double
    let speed: Double
    /// Offset into the emitter cycle, so pieces stream rather than fire in volleys.
    let phase: Double
    let size: CGFloat
    /// Turns per second.
    let spin: Double
    let color: Color
    /// An index into the layer's glyphs for the emoji pieces.
    let glyph: Int?

    /// How long one piece takes to fly, fall and fade.
    static let cycle: Double = 3.4
    static let gravity: Double = 520
    static let glyphs = ["💗", "🎉", "✨", "💞"]
    static let goldGlyphs = ["⭐️", "✨", "🏆", "🌟"]
    static let gold = [Color(red: 1.0, green: 0.80, blue: 0.35), Color(red: 0.95, green: 0.65, blue: 0.15),
                       Color(red: 1.0, green: 0.92, blue: 0.60), Theme.warm]
    /// The size the glyphs are laid out at, once; each piece scales from it.
    static let glyphSize: CGFloat = 24

    static func emitter(count: Int = 64,
                        colors: [Color] = [Theme.warm, Theme.accent, Theme.mint,
                                           Color(red: 1.0, green: 0.80, blue: 0.35)],
                        glyphCount: Int = glyphs.count) -> [ConfettiPiece] {
        return (0..<count).map { index in
            // Full-circle burst; gravity sorts out the rest.
            ConfettiPiece(angle: .random(in: 0..<(2 * .pi)),
                          speed: .random(in: 90...430),
                          phase: Double(index) / Double(count)
                              + .random(in: -0.008...0.008),
                          size: .random(in: 7...13),
                          spin: .random(in: -1.6...1.6),
                          color: colors[index % colors.count],
                          // Roughly one in four, so the emoji stay a garnish.
                          glyph: index % 4 == 0 ? (index / 4) % glyphCount : nil)
        }
    }
}

/// A few cycles of confetti from `start`, then nothing: the timeline stops.
struct ConfettiLayer: View {
    let pieces: [ConfettiPiece]
    let start: Date
    /// Each piece flies this many times.
    var cycles = 3
    var glyphs = ConfettiPiece.glyphs

    @State private var finished = false
    /// A milestone reached with the screen already open starts the layer late;
    /// its cycles count from then, not from `start`.
    @State private var appearedAt = Date()

    /// Phases only start a piece early, so the last flight ends here.
    private var duration: Double { Double(cycles) * ConfettiPiece.cycle }
    private var origin: Date { max(start, appearedAt) }

    var body: some View {
        if !finished {
            TimelineView(.animation) { timeline in
                canvas(elapsed: timeline.date.timeIntervalSince(origin))
            }
            .task(id: origin) {
                let left = duration - Date().timeIntervalSince(origin)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                if !Task.isCancelled { finished = true }
            }
        }
    }

    private func canvas(elapsed: TimeInterval) -> some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
            // Laid out once as symbols, not a `Text` per piece per frame.
            let resolved = glyphs.indices.map { context.resolveSymbol(id: $0) }

            for piece in pieces {
                // Each piece loops through the cycle, offset by its phase.
                let loops = elapsed / ConfettiPiece.cycle + piece.phase
                guard loops < Double(cycles) else { continue }
                let progress = loops.truncatingRemainder(dividingBy: 1)
                let t = progress * ConfettiPiece.cycle

                let x = origin.x + cos(piece.angle) * piece.speed * t
                let y = origin.y + sin(piece.angle) * piece.speed * t
                    + 0.5 * ConfettiPiece.gravity * t * t
                guard y < size.height + 40 else { continue }

                // Fade in fast, out slow.
                let opacity = min(1, progress / 0.06)
                    * min(1, max(0, (1 - progress) / 0.35))

                context.drawLayer { layer in
                    layer.opacity = opacity
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(piece.spin * t * 2 * .pi))
                    if let index = piece.glyph, resolved.indices.contains(index), let glyph = resolved[index] {
                        let scale = piece.size * 1.9 / ConfettiPiece.glyphSize
                        layer.scaleBy(x: scale, y: scale)
                        layer.draw(glyph, at: .zero)
                    } else {
                        let rect = CGRect(x: -piece.size / 2,
                                          y: -piece.size,
                                          width: piece.size,
                                          height: piece.size * 2)
                        layer.fill(Path(roundedRect: rect,
                                        cornerRadius: piece.size * 0.35),
                                   with: .color(piece.color))
                    }
                }
            }
        } symbols: {
            ForEach(glyphs.indices, id: \.self) { index in
                Text(glyphs[index])
                    .font(.system(size: ConfettiPiece.glyphSize))
                    .tag(index)
            }
        }
    }
}

#if DEBUG
#Preview("Celebrations") {
    TabView {
        ForEach(CelebrationStyle.allCases, id: \.self) { style in
            ZStack {
                Theme.Background()
                CelebrationOverlay(payload: StatusPayload(emoji: "🎉",
                                                          message: style == .reveal ? "we got the flat!" : "",
                                                          displayName: "Sam",
                                                          updatedAt: Date(),
                                                          nudgeCount: 0,
                                                          lastNudgeAt: nil,
                                                          isCelebration: true,
                                                          celebrationStyle: style),
                                   partnerName: "Sam") {}
                    .environment(AppModel.previewModel())
            }
            .tabItem { Text(style.rawValue) }
        }
    }
}
#endif
