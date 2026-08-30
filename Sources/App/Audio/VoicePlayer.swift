import AVFoundation
import Observation
import os

/// Plays one voice memo at a time. Owned per screen rather than globally, so
/// dismissing a screen stops its audio; `play(_:)` with a new file takes over.
@MainActor
@Observable
final class VoicePlayer {
    /// Which file is loaded, so a list of memos can ask "is it me playing?".
    private(set) var currentURL: URL?
    private(set) var isPlaying = false
    /// `0...1` through the file. Drives the progress fill under the waveform.
    private(set) var progress: Double = 0
    /// Seconds played so far, for the counter next to the waveform.
    private(set) var elapsed: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.appGroupID,
                                                 category: "VoicePlayer")

    /// Most recently started instance — used to stop another screen's player
    /// so two memos never talk over each other.
    private static weak var active: VoicePlayer?

    /// Held so `deinit` can unregister them — unremoved block observers
    /// accumulate for the life of the process.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        // A call or unplugged AirPods stops `AVAudioPlayer` underneath us;
        // without these the ticker mistakes that for end-of-file and loses the place.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, began else { return }
                self.pause()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged: hold the place, don't blast the speaker.
                guard let self, self.isPlaying, reason == .oldDeviceUnavailable else { return }
                self.pause()
            }
        })
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func isPlaying(_ url: URL) -> Bool { isPlaying && currentURL == url }

    /// Starts `url`, or resumes it if it's already the loaded file.
    func play(_ url: URL) {
        // One memo at a time, across the whole app.
        if let other = Self.active, other !== self { other.stop() }
        Self.active = self

        if currentURL == url, let player {
            resume(player)
            return
        }

        stop()
        do {
            // `.playback` so a memo is audible with the ringer switched off.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            guard player.play() else { return }
            self.player = player
            currentURL = url
            isPlaying = true
            progress = 0
            elapsed = 0
            startTicking()
        } catch {
            log.error("Couldn't play \(url.lastPathComponent): \(error.localizedDescription)")
            stop()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func toggle(_ url: URL) {
        isPlaying(url) ? pause() : play(url)
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
        progress = 0
        elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    private func resume(_ player: AVAudioPlayer) {
        // The session may have been deactivated underneath us (a call, another
        // player's stop); without re-activating, `play()` silently returns false.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("Couldn't reactivate audio session: \(error.localizedDescription)")
        }
        guard player.play() else {
            // Reset so the next tap goes through the full load path.
            log.error("Resume failed; resetting player.")
            stop()
            return
        }
        isPlaying = true
        startTicking()
    }

    /// Jumps to `fraction` (0...1) of the file — the scrub gesture on a
    /// waveform. Loads and starts `url` if it isn't the current file, so
    /// scrubbing an idle memo begins playback from that point.
    func seek(_ url: URL, to fraction: Double) {
        if currentURL != url || player == nil {
            play(url)
        }
        guard currentURL == url, let player else { return }
        let clamped = max(0, min(fraction, 1))
        // Never place the head exactly at the end — AVAudioPlayer reads that as done.
        let target = min(clamped * player.duration, max(0, player.duration - 0.05))
        player.currentTime = target
        elapsed = target
        progress = player.duration > 0 ? target / player.duration : 0
    }

    /// Polled rather than delegate-driven: the same tick has to advance the
    /// progress fill anyway, so it may as well notice the end of the file.
    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.05))
                guard let self, let player = self.player else { return }
                self.elapsed = player.currentTime
                self.progress = player.duration > 0
                    ? min(1, player.currentTime / player.duration)
                    : 0
                if !player.isPlaying {
                    // `pause()` cancels this task but may land past the check;
                    // without this guard a pause reads as end-of-file.
                    guard self.isPlaying else { return }
                    // Stopped mid-file = an interruption whose notification
                    // hasn't landed yet; hold the place. (A genuine end rewinds to 0.)
                    let midFile = player.currentTime > 0.05
                        && player.currentTime < player.duration - 0.1
                    if midFile {
                        self.pause()
                        return
                    }
                    // Reached the end: let go entirely — a loaded-but-idle
                    // player keeps waveforms drawn as zero-percent-played.
                    self.stop()
                    return
                }
            }
        }
    }
}
