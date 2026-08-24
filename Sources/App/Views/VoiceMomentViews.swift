import SwiftUI

/// What a voice memo shows in the library grid, where every cell has to be the
/// same square as the photos around it.
///
/// Drawn entirely from `Moment` metadata, never from the audio file, so a memo
/// whose recording has been evicted from the cache still looks like itself in
/// the grid. Only pressing play needs the file back.
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
        // Trailing, not leading: the library puts its own "you sent this"
        // arrow in the bottom-leading corner, and the two would collide.
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

    /// The progress fill belongs to whichever memo is actually loaded —
    /// otherwise paging mid-playback would leave a stale fill on the new page.
    /// `nil` (not `0`) when this isn't that memo, so an untouched waveform
    /// draws in full colour rather than looking entirely unplayed.
    private var progress: Double? {
        guard let audioURL, player.currentURL == audioURL else { return nil }
        return player.progress
    }

    var body: some View {
        VStack(spacing: 26) {
            WaveformBars(levels: moment.waveform,
                         progress: progress,
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

/// A voice memo at the size a voice memo actually needs: one short row with a
/// play button, rather than a square card built for a picture.
///
/// This is what the home screen shows for a memo that hasn't been heard yet.
/// Playing it here is the whole interaction — there is no bigger version of a
/// sound to open, which is exactly why it doesn't get a photo-sized frame.
struct VoiceMemoRow: View {
    let moment: Moment
    /// `nil` until the recording is on this device.
    let audioURL: URL?
    /// Owned by the enclosing screen, so leaving it stops the audio.
    let player: VoicePlayer
    /// Play, pause, or fetch-then-play — the screen decides, because fetching
    /// is async and marking the memo heard is its business, not this view's.
    let onTap: () -> Void

    private var isPlaying: Bool {
        guard let audioURL else { return false }
        return player.isPlaying(audioURL)
    }

    private var progress: Double? {
        guard let audioURL, player.currentURL == audioURL else { return nil }
        return player.progress
    }

    var body: some View {
        Button(action: onTap) {
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

                    WaveformBars(levels: moment.waveform,
                                 progress: progress,
                                 tint: Theme.accent,
                                 trackTint: Theme.accent.opacity(0.22),
                                 spacing: 2,
                                 maxBarWidth: 3)
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
        .buttonStyle(.plain)
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
