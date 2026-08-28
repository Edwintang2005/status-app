import AVFoundation
import Observation
import os

/// Records one voice memo to a temporary `.m4a`, with live metering.
///
/// Deliberately single-shot: a recorder instance holds at most one take, and
/// re-recording discards the previous file rather than accumulating takes the
/// composer would then have to manage. The file only becomes permanent when
/// `AppModel` hands it to `MomentStore`.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        /// The user said no to the microphone. Recoverable only in Settings.
        case denied
        case recording
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
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.appGroupID,
                                                 category: "VoiceRecorder")

    /// Metering interval. Fine enough that the live waveform moves with the
    /// voice rather than lurching, coarse enough to stay cheap.
    private static let tick: TimeInterval = 0.05

    var hasTake: Bool { state == .finished && fileURL != nil }

    var remaining: TimeInterval {
        max(0, AppConfig.voiceMemoMaxDuration - elapsed)
    }

    /// `0:07` — counting up while recording, so it matches what you'd expect
    /// from a voice memo rather than a countdown.
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
        guard state != .recording else { return }
        errorMessage = nil

        guard await Self.requestPermission() else {
            state = .denied
            return
        }

        discardTake()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(UUID().uuidString).m4a")

        do {
            let session = AVAudioSession.sharedInstance()
            // `.playAndRecord` rather than `.record` so previewing the take
            // doesn't need a second session change mid-composer, and
            // `.defaultToSpeaker` so the preview comes out of the speaker
            // instead of the earpiece.
            try session.setCategory(.playAndRecord,
                                    mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            // Mono AAC at 32 kHz: speech-sized, and the one encoding every
            // Apple playback and notification-attachment API takes as-is.
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
                ?? "Couldn't start recording."
            state = .idle
            // The session was activated (interrupting the user's music) before
            // the failure, and the recorder may have created the file: undo
            // both, or their podcast stays silenced over a failed take.
            try? FileManager.default.removeItem(at: url)
            deactivateSession()
        }
    }

    /// Ends the take and keeps it. Safe to call when nothing is recording.
    func stop() {
        guard state == .recording else { return }
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()

        // A tap so short it caught no audio isn't a memo; treat it as nothing
        // rather than sending an empty file.
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
        recorder?.stop()
        recorder = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        elapsed = 0
        levels = []
        state = state == .denied ? .denied : .idle
        deactivateSession()
    }

    /// Called when the composer goes away with a take still unsent.
    func cleanUp() {
        discardTake()
    }

    /// Hands the file off to whoever is sending it and forgets about it —
    /// **without** deleting it. The recorder owns the temporary file right up
    /// to this point, and `cleanUp()` would otherwise race the upload and pull
    /// the recording out from under it.
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
            // `record(forDuration:)` stopped us at the ceiling.
            stopAtLimit()
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
        // Not only the duration ceiling lands here: a phone call, Siri or an
        // alarm stops `AVAudioRecorder` underneath us and the next tick
        // arrives with `isRecording == false`. The same too-short rule as
        // `stop()` applies — without it, an interruption moments into a take
        // left a sendable, near-empty file.
        if fileURL == nil || elapsed < 0.6 {
            discardTake()
        } else {
            state = .finished
        }
    }

    private func deactivateSession() {
        // Non-fatal: another sound may still be finishing, and there is
        // nothing useful to tell the user about it.
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    /// `averagePower` is dBFS, which is roughly `-160` (silence) to `0`
    /// (clipping) but sits between `-50` and `-5` for a person talking at arm's
    /// length. Mapping that range — rather than the full one — is what stops
    /// every waveform being a flat line near zero.
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
            return "The microphone is busy. Try again in a moment."
        }
    }
}
