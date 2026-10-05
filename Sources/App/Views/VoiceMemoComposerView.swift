import SwiftUI

/// Record a voice memo and send it to the other person.
struct VoiceMemoComposerView: View {
    /// The recording is handed over as a temporary file the caller must move,
    /// along with the metadata that can't be recovered from it afterwards.
    var onSend: (URL, TimeInterval, [Double], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var recorder = VoiceRecorder()
    @State private var player = VoicePlayer()
    @State private var caption = ""
    @State private var confirmingDiscard = false
    @State private var confirmingRedo = false
    @FocusState private var captionFocused: Bool

    /// A take in progress or in hand, or words typed for it.
    private var hasContent: Bool {
        recorder.state == .recording || recorder.state == .paused || recorder.hasTake || !caption.isEmpty
    }

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
                                .foregroundStyle(Theme.warmText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Voice memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasContent { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .font(Theme.rounded(17, .semibold))
                        .disabled(!recorder.hasTake)
                }
            }
            .confirmationDialog("Discard this recording?",
                                isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep it", role: .cancel) {}
            }
        }
        // A two-minute take must not vanish on an accidental pull-down.
        .interactiveDismissDisabled(hasContent)
        .onDisappear {
            player.stop()
            // A no-op once `send()` has handed the file over.
            recorder.cleanUp()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding stops the take — never record behind the user's back.
            // Not `.inactive`: Control Centre or a banner pulled down would cut it short.
            if phase == .background { recorder.stop() }
        }
        .onChange(of: recorder.state) { old, new in announce(from: old, to: new) }
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 20) {
            Text(statusLine)
                .font(Theme.rounded(15, .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
                // Warm in the last half-minute: the take stops itself at the cap.
                .foregroundStyle(nearCap ? Theme.warmText : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .card(padding: 24)
    }

    /// While recording, a fixed-width window on the tail of the take (left-padded
    /// so bars scroll in at constant width); afterwards, the condensed whole take.
    private var displayedLevels: [Double] {
        guard recorder.state == .recording || recorder.state == .paused else { return recorder.waveform }
        let slots = AppConfig.voiceWaveformSampleCount
        let tail = Array(recorder.levels.suffix(slots))
        return Array(repeating: 0, count: max(0, slots - tail.count)) + tail
    }

    /// `nil` until the take is loaded, so the waveform shows full colour, not unplayed.
    private var previewProgress: Double? {
        guard let url = recorder.fileURL, player.currentURL == url else { return nil }
        return player.progress
    }

    /// Idle placeholder stays faint so it doesn't read as a recording.
    private var waveformTint: Color {
        switch recorder.state {
        case .recording: return Theme.warm
        case .paused: return Theme.warm.opacity(0.5)
        case .finished: return Theme.accent
        case .idle, .denied: return Color.primary.opacity(0.16)
        }
    }

    private var statusLine: String {
        switch recorder.state {
        case .idle:
            return String(localized: "Ready when you are · up to \(Self.timeLabel(AppConfig.voiceMemoMaxDuration))")
        case .denied:
            return String(localized: "\(AppConfig.appName) needs the microphone")
        case .recording:
            return String(localized: "Recording…")
        case .paused:
            return String(localized: "Recording paused · tap Resume to carry on")
        case .finished:
            return player.isPlaying ? String(localized: "Playing") : String(localized: "Listen back, or send it")
        }
    }

    private var counter: String {
        if recorder.hasTake, player.isPlaying {
            return Self.timeLabel(player.elapsed)
        }
        if recorder.state == .recording || recorder.state == .paused {
            return "\(recorder.elapsedLabel) / \(Self.timeLabel(AppConfig.voiceMemoMaxDuration))"
        }
        return recorder.elapsedLabel
    }

    private var nearCap: Bool {
        recorder.state == .recording && AppConfig.voiceMemoMaxDuration - recorder.elapsed <= 30
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

        case .paused:
            HStack(spacing: 12) {
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "mic.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    recorder.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

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
                    // A few seconds is quick to redo; a real take asks first.
                    if recorder.elapsed > 10 { confirmingRedo = true } else { redo() }
                } label: {
                    Label("Redo", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .confirmationDialog("Record again?",
                                    isPresented: $confirmingRedo,
                                    titleVisibility: .visible) {
                    Button("Record again", role: .destructive) { redo() }
                    Button("Keep this take", role: .cancel) {}
                } message: {
                    Text("This take will be lost.")
                }
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
        .buttonStyle(PrimaryButtonStyle(tint: recording ? Theme.warmDeep : Theme.accent))
        .animation(.smooth(duration: 0.2), value: recording)
    }

    private func redo() {
        player.stop()
        recorder.discardTake()
    }

    /// The status line changes silently; VoiceOver hears the take start and end.
    private func announce(from old: VoiceRecorder.State, to new: VoiceRecorder.State) {
        let words: String
        switch new {
        case .recording:
            words = old == .paused ? String(localized: "Recording again") : String(localized: "Recording")
        case .paused:
            words = String(localized: "Recording paused. Resume to carry on.")
        case .finished:
            words = String(localized: "Recording stopped at \(recorder.elapsedLabel)")
        case .idle where old == .recording:
            words = String(localized: "Too short to keep. Record again.")
        default:
            return
        }
        AccessibilityNotification.Announcement(words).post()
    }

    private var captionField: some View {
        VStack(spacing: 6) {
            captionInput
            CharacterCount(count: caption.count, limit: AppConfig.captionMaxLength)
        }
    }

    private var captionInput: some View {
        TextField("Add a caption (optional)", text: $caption)
            .font(Theme.rounded(16))
            .focused($captionFocused)
            .submitLabel(.done)
            .onChange(of: caption) { _, text in
                if text.count > AppConfig.captionMaxLength {
                    caption = String(text.prefix(AppConfig.captionMaxLength))
                }
            }
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
        // File ownership passes to the caller; relinquish before `onDisappear` tidies up.
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
