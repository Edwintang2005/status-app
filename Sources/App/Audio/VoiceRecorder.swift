import AVFoundation
import Observation
import os

/// Records one voice memo to a temporary `.m4a`, with live metering. Single-shot:
/// re-recording discards the previous take; the file only becomes permanent when `AppModel` hands it to `MomentStore`.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        /// The user said no to the microphone. Recoverable only in Settings.
        case denied
        case recording
        /// A call, Siri or an alarm took the microphone mid-take. The take so
        /// far is kept; `resume()` carries on in the same file, `stop()` keeps it.
        case paused
        /// A take exists at `fileURL` and can be previewed or sent.
        case finished
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Every loudness sample so far, `0...1`, oldest first. The composer draws
    /// the tail of this live; `waveform` condenses the whole thing at the end.
    private(set) var levels: [Double] = []
    private(set) var errorMessage: String?

    /// The finished take, or `nil` before the first one.
    @ObservationIgnored private(set) var fileURL: URL?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// `start()` is past its state check and awaiting the microphone permission.
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.appGroupID,
                                                 category: "VoiceRecorder")
    /// Held so `deinit` can unregister it (see `VoicePlayer.observers`).
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?

    /// Metering interval: fine enough to move with the voice, coarse enough to stay cheap.
    private static let tick: TimeInterval = 0.05

    var hasTake: Bool { state == .finished && fileURL != nil }

    init() {
        // Without this the ticker reads the recorder stopping underneath it as
        // the take's end, and a phone call finishes a memo the user wasn't done with.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated {
                guard began else { return }
                self?.pause()
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    var remaining: TimeInterval {
        max(0, AppConfig.voiceMemoMaxDuration - elapsed)
    }

    /// `0:07` — counts up while recording, not down.
    var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The take condensed to `AppConfig.voiceWaveformSampleCount` buckets, for
    /// storing on the `Moment`.
    var waveform: [Double] {
        Waveform.condense(levels, into: AppConfig.voiceWaveformSampleCount)
    }

    // MARK: - Recording

    func start() async {
        // Claimed before the permission await: two quick taps both passed the
        // state check and the second recorder overwrote the first.
        guard !isTaking, !starting else { return }
        starting = true
        defer { starting = false }
        errorMessage = nil

        guard await Self.requestPermission() else {
            state = .denied
            return
        }

        discardTake()
        // Recording re-categorises the session; a memo left playing would stall
        // under it and keep showing as playing.
        VoicePlayer.stopActive()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(UUID().uuidString).m4a")

        do {
            let session = AVAudioSession.sharedInstance()
            // `.playAndRecord` so previewing needs no second session change;
            // `.defaultToSpeaker` so the preview isn't in the earpiece.
            try session.setCategory(.playAndRecord,
                                    mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            // Mono AAC at 32 kHz: speech-sized, and taken as-is by every Apple
            // playback and notification-attachment API.
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 32_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: AppConfig.voiceMemoMaxDuration) else {
                throw VoiceRecorderError.couldNotStart
            }

            self.recorder = recorder
            self.fileURL = url
            elapsed = 0
            levels = []
            state = .recording
            startTicking()
        } catch {
            log.error("Couldn't start recording: \(error.localizedDescription)")
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Couldn't start recording.")
            state = .idle
            // The session was activated before the failure and the file may
            // exist: undo both, or the user's audio stays silenced.
            try? FileManager.default.removeItem(at: url)
            deactivateSession()
        }
    }

    /// Holds the take where it is; only an interruption calls this.
    private func pause() {
        guard state == .recording, let recorder else { return }
        ticker?.cancel()
        ticker = nil
        recorder.pause()
        state = .paused
    }

    /// Carries on recording into the same file after an interruption.
    func resume() {
        guard state == .paused, let recorder else { return }
        errorMessage = nil
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard recorder.record() else { throw VoiceRecorderError.couldNotStart }
            state = .recording
            startTicking()
        } catch {
            log.error("Couldn't resume recording: \(error.localizedDescription)")
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Couldn't start recording.")
        }
    }

    /// A take is under way: recording, or paused by an interruption.
    var isTaking: Bool { state == .recording || state == .paused }

    /// Ends the take and keeps it. Safe to call when nothing is recording.
    func stop() {
        guard isTaking else { return }
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()

        // A sub-0.6 s take isn't a memo; don't offer an empty file to send.
        if elapsed < 0.6 {
            discardTake()
            state = .idle
        } else {
            state = .finished
        }
    }

    /// Throws the take away, back to the empty state.
    func discardTake() {
        ticker?.cancel()
        ticker = nil
        // Like `VoicePlayer.stop()`: an idle composer closing mustn't silence a memo.
        let ownedSession = recorder != nil
        recorder?.stop()
        recorder = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        elapsed = 0
        levels = []
        state = state == .denied ? .denied : .idle
        if ownedSession { deactivateSession() }
    }

    /// Called when the composer goes away with a take still unsent.
    func cleanUp() {
        discardTake()
    }

    /// Hands the file off **without** deleting it — otherwise `cleanUp()`
    /// would race the upload and pull the recording out from under it.
    func relinquish() {
        ticker?.cancel()
        ticker = nil
        recorder = nil
        fileURL = nil
        elapsed = 0
        levels = []
        state = .idle
    }

    // MARK: - Metering

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tick))
                guard let self, self.state == .recording else { return }
                self.sample()
            }
        }
    }

    private func sample() {
        guard let recorder, recorder.isRecording else {
            // Short of the ceiling, an interruption whose notification trails
            // this tick: hold the take. At it, `record(forDuration:)` stopped us.
            if self.recorder != nil, elapsed < AppConfig.voiceMemoMaxDuration - 1 { pause() } else { stopAtLimit() }
            return
        }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        levels.append(Self.normalize(recorder.averagePower(forChannel: 0)))

        if elapsed >= AppConfig.voiceMemoMaxDuration {
            stopAtLimit()
        }
    }

    private func stopAtLimit() {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()
        // The same too-short rule as `stop()`.
        if fileURL == nil || elapsed < 0.6 {
            discardTake()
        } else {
            state = .finished
        }
    }

    private func deactivateSession() {
        // Non-fatal: another sound may still be finishing.
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    /// dBFS sits between `-50` and `-5` for speech at arm's length; mapping
    /// that range (not the full one) stops every waveform flatlining near zero.
    private static func normalize(_ decibels: Float) -> Double {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        let clamped = max(floor, min(0, decibels))
        return Double((clamped - floor) / -floor)
    }

    // MARK: - Permission

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }
}

enum VoiceRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return String(localized: "The microphone is busy. Try again in a moment.")
        }
    }
}
