import SwiftUI

/// The greeting the recipient gets the first time they open the app after an
/// anniversary status arrives — see `Snapshot.pendingCelebration` for when that
/// is, and `AppModel.celebrationPlayed()` for what retires it.
///
/// Their words are the whole design. Everything else — the confetti, the bloom,
/// the emoji — orbits a single centred line of text, because "happy 3 months"
/// is the message and the animation is only the envelope it arrives in.
struct CelebrationOverlay: View {
    let payload: StatusPayload
    let partnerName: String
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// Fixed at init so the confetti doesn't reshuffle on every redraw — the
    /// timeline animates these pieces, it doesn't regenerate them.
    @State private var pieces = ConfettiPiece.emitter()
    @State private var start = Date()

    /// Their text, or a stand-in if they armed a celebration and sent no words.
    private var headline: String {
        let trimmed = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Happy anniversary" : trimmed
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
        // The whole screen dismisses, so nothing underneath can be tapped by
        // accident while the confetti is still falling.
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). From \(partnerName).")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(named: "Dismiss", finish)
        .task {
            start = .now
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { revealed = true }
        }
    }

    // MARK: - Layers

    /// Material rather than an opaque fill: the home screen staying faintly
    /// visible underneath is what makes this read as something landing *on* the
    /// app rather than as another screen.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            RadialGradient(colors: [Theme.warm.opacity(0.55), .clear],
                           center: .center,
                           startRadius: 0,
                           endRadius: 420)
                .scaleEffect(revealed ? 1 : 0.2)
                .opacity(revealed ? 1 : 0)
            RadialGradient(colors: [Theme.accent.opacity(0.40), .clear],
                           center: UnitPoint(x: 0.5, y: 0.72),
                           startRadius: 0,
                           endRadius: 360)
                .scaleEffect(revealed ? 1 : 0.2)
                .opacity(revealed ? 1 : 0)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text(payload.emoji)
                .font(.system(size: 84))
                .scaleEffect(revealed ? 1 : 0.3)
                .rotationEffect(.degrees(revealed ? 0 : -25))
                .padding(.bottom, 26)

            // The centred line the whole feature exists for. Sized to fit
            // rather than truncated: an anniversary is exactly the moment
            // someone types more than three words.
            Text(headline)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.45)
                .foregroundStyle(.primary)
                .shadow(color: Theme.warm.opacity(0.35), radius: 18)
                .scaleEffect(revealed ? 1 : 0.8)
                .opacity(revealed ? 1 : 0)
                .padding(.horizontal, 34)

            Text("from \(partnerName)")
                .font(Theme.rounded(17, .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
                .opacity(revealed ? 1 : 0)

            Spacer(minLength: 0)

            Button(action: finish) {
                Label("Love it", systemImage: "heart.fill")
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.warm))
            .padding(.horizontal, 44)
            .opacity(revealed ? 1 : 0)
            // Last in, and only once the words have landed: dismissing is not
            // what anyone should be looking at first.
            .animation(.smooth(duration: 0.4).delay(0.7), value: revealed)

            Text("Tap anywhere to close")
                .font(Theme.rounded(12))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
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

/// One piece of confetti, launched from the centre of the screen on a ballistic
/// arc. Everything about it is decided once, up front; its position is a pure
/// function of elapsed time, which is what lets the whole layer be a single
/// `Canvas` redrawn by a `TimelineView` instead of hundreds of animating views.
private struct ConfettiPiece: Identifiable {
    let id = UUID()
    /// Launch direction in radians, and speed in points per second.
    let angle: Double
    let speed: Double
    /// Offset into the emitter cycle, so pieces stream continuously rather
    /// than firing in visible volleys.
    let phase: Double
    let size: CGFloat
    /// Turns per second.
    let spin: Double
    let color: Color
    /// Non-nil for the emoji pieces, which carry the warmth the plain
    /// rectangles can't.
    let glyph: String?

    /// How long one piece takes to fly, fall and fade.
    static let cycle: Double = 3.4
    static let gravity: Double = 520

    static func emitter(count: Int = 64) -> [ConfettiPiece] {
        let colors = [Theme.warm, Theme.accent, Theme.mint,
                      Color(red: 1.0, green: 0.80, blue: 0.35)]
        let glyphs = ["💗", "🎉", "✨", "💞"]

        return (0..<count).map { index in
            // A full circle, so the burst reads as coming from behind the text
            // in every direction; gravity sorts out the rest.
            ConfettiPiece(angle: .random(in: 0..<(2 * .pi)),
                          speed: .random(in: 90...430),
                          phase: Double(index) / Double(count)
                              + .random(in: -0.008...0.008),
                          size: .random(in: 7...13),
                          spin: .random(in: -1.6...1.6),
                          color: colors[index % colors.count],
                          // Roughly one in four, so the emoji stay a garnish.
                          glyph: index % 4 == 0 ? glyphs[(index / 4) % glyphs.count] : nil)
        }
    }
}

private struct ConfettiLayer: View {
    let pieces: [ConfettiPiece]
    let start: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)

                for piece in pieces {
                    // Each piece runs its own loop through the cycle, offset by
                    // its phase — one pass of the maths, endlessly.
                    let progress = (elapsed / ConfettiPiece.cycle + piece.phase)
                        .truncatingRemainder(dividingBy: 1)
                    let t = progress * ConfettiPiece.cycle

                    let x = origin.x + cos(piece.angle) * piece.speed * t
                    let y = origin.y + sin(piece.angle) * piece.speed * t
                        + 0.5 * ConfettiPiece.gravity * t * t
                    guard y < size.height + 40 else { continue }

                    // In fast, out slow: a piece should be visible from the
                    // moment it leaves the centre.
                    let opacity = min(1, progress / 0.06)
                        * min(1, max(0, (1 - progress) / 0.35))

                    context.drawLayer { layer in
                        layer.opacity = opacity
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(piece.spin * t * 2 * .pi))
                        if let glyph = piece.glyph {
                            layer.draw(Text(glyph).font(.system(size: piece.size * 1.9)),
                                       at: .zero)
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
    }
}
#endif
