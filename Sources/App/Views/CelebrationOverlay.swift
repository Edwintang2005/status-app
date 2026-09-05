import SwiftUI

/// Shown on first open after an anniversary status arrives — see
/// `Snapshot.pendingCelebration` and `AppModel.celebrationPlayed()`.
struct CelebrationOverlay: View {
    let payload: StatusPayload
    let partnerName: String
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// Fixed at init so the confetti doesn't reshuffle on every redraw.
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
        // Whole screen dismisses; nothing underneath is tappable by accident.
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

    /// Material, not opaque: the home screen faintly showing through makes this
    /// read as landing *on* the app, not another screen.
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

            // Sized to fit rather than truncated — anniversary messages run long.
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
            // Delayed until the words have landed.
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
    /// Non-nil for the emoji pieces.
    let glyph: String?

    /// How long one piece takes to fly, fall and fade.
    static let cycle: Double = 3.4
    static let gravity: Double = 520

    static func emitter(count: Int = 64) -> [ConfettiPiece] {
        let colors = [Theme.warm, Theme.accent, Theme.mint,
                      Color(red: 1.0, green: 0.80, blue: 0.35)]
        let glyphs = ["💗", "🎉", "✨", "💞"]

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
                          glyph: index % 4 == 0 ? glyphs[(index / 4) % glyphs.count] : nil)
        }
    }
}

struct ConfettiLayer: View {
    let pieces: [ConfettiPiece]
    let start: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)

                for piece in pieces {
                    // Each piece loops through the cycle, offset by its phase.
                    let progress = (elapsed / ConfettiPiece.cycle + piece.phase)
                        .truncatingRemainder(dividingBy: 1)
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
