import SwiftUI

/// A voice memo's square tile in the library grid. Drawn entirely from `Moment`
/// metadata, never the audio file, so an evicted recording still renders.
struct VoiceMomentTile: View {
    let moment: Moment

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.30), Theme.warm.opacity(0.22)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            WaveformBars(levels: moment.waveform,
                         progress: nil,
                         tint: Theme.accent.opacity(0.85),
                         spacing: 1.5,
                         maxBarWidth: 3)
                .frame(height: 34)
                .padding(.horizontal, 10)
        }
        // Trailing, not leading — the library's sent-arrow owns bottom-leading.
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                Text(moment.durationLabel).monospacedDigit()
            }
            .font(Theme.rounded(10, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(6)
        }
        .accessibilityLabel("Voice memo, \(moment.durationLabel)")
    }
}

/// The gallery's page for a voice memo: a big play control over the waveform,
/// with the played portion filling in as it goes.
struct VoicePlaybackCard: View {
    let moment: Moment
    /// `nil` while the recording is still being fetched, or if it couldn't be.
    let audioURL: URL?
    /// Owned by the enclosing screen, so dismissing it stops the audio.
    let player: VoicePlayer

    private var isPlaying: Bool {
        guard let audioURL else { return false }
        return player.isPlaying(audioURL)
    }

    var body: some View {
        VStack(spacing: 26) {
            // Tap or swipe anywhere on the waveform to scrub.
            ScrubbableWaveform(moment: moment,
                               audioURL: audioURL,
                               player: player,
                               tint: Theme.accent,
                               trackTint: Color.primary.opacity(0.18),
                               spacing: 3)
                .frame(height: 110)

            HStack(spacing: 14) {
                Button {
                    guard let audioURL else { return }
                    player.toggle(audioURL)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(Theme.accent, in: Circle())
                        .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(audioURL == nil)
                .opacity(audioURL == nil ? 0.4 : 1)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 2) {
                    Text(isPlaying ? timeLabel(player.elapsed) : moment.durationLabel)
                        .font(Theme.rounded(28, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("voice memo")
                        .font(Theme.rounded(13))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 30)
        .card(padding: 26)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The home screen's row for an unheard memo: one short row with a play
/// button — playing it here is the whole interaction.
struct VoiceMemoRow: View {
    let moment: Moment
    /// `nil` until the recording is on this device.
    let audioURL: URL?
    /// Owned by the enclosing screen, so leaving it stops the audio.
    let player: VoicePlayer
    /// Play, pause, or fetch-then-play — the enclosing screen decides;
    /// marking the memo heard is its business, not this view's.
    let onTap: () -> Void
    /// Fires when a scrub starts, so the enclosing screen can mark it heard.
    var onScrub: (() -> Void)? = nil

    private var isPlaying: Bool {
        guard let audioURL else { return false }
        return player.isPlaying(audioURL)
    }

    // Not a Button: a wrapping Button claims touches before the waveform's
    // scrub gesture can, so the card takes a tap gesture instead.
    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            // One element: double-tap plays, swipe up/down scrubs.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(moment.durationLabel)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(isPlaying ? "Pauses" : "Plays")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAdjustableAction { direction in
                guard let audioURL else { return }
                onScrub?()
                player.seek(audioURL, by: direction == .increment ? 0.1 : -0.1)
            }
    }

    private var accessibilityValue: String {
        if isPlaying { return String(localized: "Playing") }
        return !moment.seen && !moment.fromMe ? String(localized: "New") : ""
    }

    private var content: some View {
            HStack(spacing: 14) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Theme.rounded(15, .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(isPlaying ? timeLabel(player.elapsed) : moment.durationLabel)
                            .font(Theme.rounded(13))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    // Swipe sideways to scrub; taps still reach the row, and a
                    // vertical swipe still scrolls the home screen.
                    ScrubbableWaveform(moment: moment,
                                       audioURL: audioURL,
                                       player: player,
                                       tint: Theme.accent,
                                       trackTint: Theme.accent.opacity(0.22),
                                       spacing: 2,
                                       maxBarWidth: 3,
                                       scrollSafe: true,
                                       onScrubStart: onScrub)
                        .frame(height: 22)
                }
            }
            .card(padding: 14)
            .overlay(alignment: .topTrailing) {
                if !moment.seen && !moment.fromMe {
                    Circle()
                        .fill(Theme.warm)
                        .frame(width: 9, height: 9)
                        .offset(x: -6, y: 6)
                }
            }
    }

    private var title: String {
        if !moment.caption.isEmpty { return moment.caption }
        let sender = moment.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return moment.fromMe
            ? "Your voice memo"
            : (sender.isEmpty ? "Voice memo" : "\(sender) sent a voice memo")
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#if DEBUG
private let sampleMemo = Moment(
    kind: .voice,
    caption: "listen to this",
    senderName: "Sam",
    fromMe: false,
    duration: 14,
    waveform: (0..<48).map { abs(sin(Double($0) / 2.5)) * 0.85 + 0.1 }
)

#Preview("Voice memo views") {
    ScrollView {
        VStack(spacing: 20) {
            VoiceMemoRow(moment: sampleMemo, audioURL: nil, player: VoicePlayer()) {}
            HStack(spacing: 8) {
                SquareFill { VoiceMomentTile(moment: sampleMemo) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(width: 104)
                Spacer()
            }
            VoicePlaybackCard(moment: sampleMemo, audioURL: nil, player: VoicePlayer())
        }
        .padding()
    }
    .background(Theme.Background())
}
#endif
