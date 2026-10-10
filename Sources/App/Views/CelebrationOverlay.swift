import SwiftUI

/// Shown on first open after an anniversary status arrives — see
/// `Snapshot.pendingCelebration` and `AppModel.celebrationPlayed()`.
struct CelebrationOverlay: View {
    let payload: StatusPayload
    let partnerName: String
    let onDismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// Fixed at init so the confetti doesn't reshuffle on every redraw.
    @State private var pieces = ConfettiPiece.emitter()
    @State private var start = Date()
    @State private var confirmingReport = false

    /// Their status as it may be shown; this fills the screen (invariant 20).
    private var shown: ModeratedStatus {
        payload.moderation(reportedAt: model.hiddenPartnerStatusAt, filterEnabled: model.contentFilterEnabled)
    }

    /// Their words, or a stand-in if they armed a celebration and sent none —
    /// or the words can't be shown.
    private var headline: String {
        let message = shown.message
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !message.isPlaceholder else { return String(localized: "Happy anniversary") }
        return trimmed
    }

    var body: some View {
        ZStack {
            backdrop
            if !reduceMotion {
                ConfettiLayer(pieces: pieces, start: start)
                    .allowsHitTesting(false)
            }
            content
        }
        .ignoresSafeArea()
        // Whole screen dismisses; nothing underneath is tappable by accident.
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). From \(partnerName).")
        .accessibilityAddTraits(.isModal)
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

    // MARK: - Layers

    /// Material, not opaque: the home screen faintly showing through makes this
    /// read as landing *on* the app, not another screen.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            RadialGradient(colors: [Theme.warm.opacity(0.55), .clear],
                           center: .center,
                           startRadius: 0,
                           endRadius: 420)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.2)
                .opacity(revealed ? 1 : 0)
            RadialGradient(colors: [Theme.accent.opacity(0.40), .clear],
                           center: UnitPoint(x: 0.5, y: 0.72),
                           startRadius: 0,
                           endRadius: 360)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.2)
                .opacity(revealed ? 1 : 0)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text(shown.emoji)
                .font(.system(size: 84))
                // Under Reduce Motion everything here only fades.
                .scaleEffect(revealed || reduceMotion ? 1 : 0.3)
                .rotationEffect(.degrees(revealed || reduceMotion ? 0 : -25))
                .opacity(revealed ? 1 : 0)
                .padding(.bottom, 26)

            // Sized to fit rather than truncated — anniversary messages run long.
            Text(headline)
                .font(Theme.rounded(44, .bold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.45)
                .foregroundStyle(.primary)
                .shadow(color: Theme.warm.opacity(0.35), radius: 18)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.8)
                .opacity(revealed ? 1 : 0)
                .padding(.horizontal, 34)

            Text("from \(partnerName)")
                .font(Theme.rounded(17, .medium))
                .foregroundStyle(Theme.mutedText)
                .padding(.top, 18)
                .opacity(revealed ? 1 : 0)

            Spacer(minLength: 0)

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

            Button("Report...") { confirmingReport = true }
                .font(Theme.rounded(13, .medium))
                .foregroundStyle(Theme.mutedText)
                .frame(minWidth: 44, minHeight: 44)
                .opacity(revealed ? 1 : 0)
                .animation(.smooth(duration: 0.4).delay(1.1), value: revealed)
        }
        .padding(.vertical, 64)
    }

    private func finish() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onDismiss()
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
    /// An index into `glyphs` for the emoji pieces.
    let glyph: Int?

    /// How long one piece takes to fly, fall and fade.
    static let cycle: Double = 3.4
    static let gravity: Double = 520
    static let glyphs = ["💗", "🎉", "✨", "💞"]
    /// The size the glyphs are laid out at, once; each piece scales from it.
    static let glyphSize: CGFloat = 24

    static func emitter(count: Int = 64) -> [ConfettiPiece] {
        let colors = [Theme.warm, Theme.accent, Theme.mint,
                      Color(red: 1.0, green: 0.80, blue: 0.35)]

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
                          glyph: index % 4 == 0 ? (index / 4) % glyphs.count : nil)
        }
    }
}

/// A few cycles of confetti from `start`, then nothing: the timeline stops.
struct ConfettiLayer: View {
    let pieces: [ConfettiPiece]
    let start: Date
    /// Each piece flies this many times.
    var cycles = 3

    @State private var finished = false

    /// Phases only start a piece early, so the last flight ends here.
    private var duration: Double { Double(cycles) * ConfettiPiece.cycle }

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
            let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
            // Laid out once as symbols, not a `Text` per piece per frame.
            let glyphs = ConfettiPiece.glyphs.indices.map { context.resolveSymbol(id: $0) }

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
                    if let index = piece.glyph, let glyph = glyphs[index] {
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
            ForEach(ConfettiPiece.glyphs.indices, id: \.self) { index in
                Text(ConfettiPiece.glyphs[index])
                    .font(.system(size: ConfettiPiece.glyphSize))
                    .tag(index)
            }
        }
    }
}

#if DEBUG
#Preview("Celebration") {
    ZStack {
        Theme.Background()
        CelebrationOverlay(payload: StatusPayload(emoji: "🎉",
                                                  message: "happy 3 months",
                                                  displayName: "Sam",
                                                  updatedAt: Date(),
                                                  nudgeCount: 0,
                                                  lastNudgeAt: nil,
                                                  isCelebration: true),
                           partnerName: "Sam") {}
            .environment(AppModel.previewModel())
    }
}
#endif
