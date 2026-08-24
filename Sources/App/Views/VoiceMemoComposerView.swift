import SwiftUI

/// Record a voice memo and send it to the other person.
///
/// Its own screen rather than a fourth tab in `MomentComposerView`: a memo has
/// no image to compose over, and the two share nothing but the caption field.
struct VoiceMemoComposerView: View {
    /// The recording is handed over as a temporary file the caller must move,
    /// along with the metadata that can't be recovered from it afterwards.
    var onSend: (URL, TimeInterval, [Double], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var recorder = VoiceRecorder()
    @State private var player = VoicePlayer()
    @State private var caption = ""
    @FocusState private var captionFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollView {
                    VStack(spacing: 18) {
                        stage
                        controls
                        captionField
                        if let message = recorder.errorMessage {
                            Text(message)
                                .font(Theme.rounded(13))
                                .foregroundStyle(Theme.warm)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Send a voice memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .font(Theme.rounded(17, .semibold))
                        .disabled(!recorder.hasTake)
                }
            }
        }
        .onDisappear {
            player.stop()
            // A no-op once `send()` has handed the file over.
            recorder.cleanUp()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding mid-take keeps whatever was captured rather than
            // leaving a recording running behind the user's back.
            if phase != .active { recorder.stop() }
        }
    }

    // MARK: - Stage

    /// The one thing this screen is about, sized like the composer's square so
    /// the two sheets feel like siblings.
    private var stage: some View {
        VStack(spacing: 20) {
            Text(statusLine)
                .font(Theme.rounded(15, .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)

            WaveformBars(levels: displayedLevels,
                         progress: previewProgress,
                         tint: waveformTint,
                         trackTint: Color.primary.opacity(0.15))
                .frame(height: 96)
                .animation(.linear(duration: 0.08), value: displayedLevels)

            Text(counter)
                .font(Theme.rounded(34, .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .card(padding: 24)
    }

    /// While recording, a fixed-width window onto the tail of the take, padded
    /// on the left so the bars scroll in from the right at a constant width
    /// instead of starting as three slabs. Afterwards, the whole thing
    /// condensed — the same samples that get stored on the moment.
    private var displayedLevels: [Double] {
        guard recorder.state == .recording else { return recorder.waveform }
        let slots = AppConfig.voiceWaveformSampleCount
        let tail = Array(recorder.levels.suffix(slots))
        return Array(repeating: 0, count: max(0, slots - tail.count)) + tail
    }

    /// Only once the take is loaded in the player — before that, `nil` keeps
    /// the whole waveform in full colour instead of showing it as unplayed.
    private var previewProgress: Double? {
        guard let url = recorder.fileURL, player.currentURL == url else { return nil }
        return player.progress
    }

    /// The empty state's placeholder row is a stand-in, not a recording, so it
    /// stays quiet enough to read as one.
    private var waveformTint: Color {
        switch recorder.state {
        case .recording: return Theme.warm
        case .finished: return Theme.accent
        case .idle, .denied: return Color.primary.opacity(0.16)
        }
    }

    private var statusLine: String {
        switch recorder.state {
        case .idle:
            return "Tap to record"
        case .denied:
            return "\(AppConfig.appName) needs the microphone"
        case .recording:
            return "Recording — tap to stop"
        case .finished:
            return player.isPlaying ? "Playing" : "Listen back, or send it"
        }
    }

    private var counter: String {
        if recorder.hasTake, player.isPlaying {
            return Self.timeLabel(player.elapsed)
        }
        return recorder.elapsedLabel
    }

    private static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .denied:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(PrimaryButtonStyle())

        case .finished:
            HStack(spacing: 12) {
                Button {
                    guard let url = recorder.fileURL else { return }
                    player.toggle(url)
                } label: {
                    Label(player.isPlaying ? "Pause" : "Play",
                          systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    player.stop()
                    recorder.discardTake()
                } label: {
                    Label("Redo", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

        default:
            recordButton
        }
    }

    private var recordButton: some View {
        let recording = recorder.state == .recording
        return Button {
            captionFocused = false
            if recording {
                recorder.stop()
            } else {
                Task { await recorder.start() }
            }
        } label: {
            Label(recording ? "Stop" : "Record",
                  systemImage: recording ? "stop.fill" : "mic.fill")
        }
        .buttonStyle(PrimaryButtonStyle(tint: recording ? Theme.warm : Theme.accent))
        .animation(.smooth(duration: 0.2), value: recording)
    }

    private var captionField: some View {
        TextField("Add a caption (optional)", text: $caption)
            .font(Theme.rounded(16))
            .focused($captionFocused)
            .submitLabel(.done)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Sending

    private func send() {
        guard let url = recorder.fileURL, recorder.hasTake else { return }
        let duration = recorder.elapsed
        let waveform = recorder.waveform

        player.stop()
        // Ownership of the file passes to the caller here; the recorder must
        // stop treating it as its own before `onDisappear` tidies up.
        recorder.relinquish()
        onSend(url, duration, waveform, caption)
        dismiss()
    }
}

#if DEBUG
#Preview("Voice memo") {
    VoiceMemoComposerView { _, _, _, _ in }
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
