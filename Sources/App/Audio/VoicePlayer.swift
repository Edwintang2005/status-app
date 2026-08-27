import AVFoundation
import Observation
import os

/// Plays one voice memo at a time.
///
/// Owned per screen rather than globally: the gallery and the composer each
/// keep their own, and dismissing either stops its audio because the player
/// goes with it. Paging in the gallery calls `play(_:)` with a new file, which
/// takes over from whatever was playing.
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

    /// Whichever player instance most recently started. Screens each own a
    /// player, and nothing else stops the home screen's memo when the gallery
    /// starts one over it — two recordings talking over each other.
    private static weak var active: VoicePlayer?

    /// Held so `deinit` can unregister them — a player is created per screen
    /// presentation, and unremoved block observers accumulate for the life of
    /// the process.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        // A phone call or unplugged AirPods stops `AVAudioPlayer` underneath
        // us; without these observers the ticker mistook that for the end of
        // the file and threw away the listener's place.
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
                // Headphones unplugged mid-memo: hold the place rather than
                // blasting the rest out of the speaker.
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
            // `.playback` so a memo is audible with the ringer switched off —
            // someone who taps play has asked to hear it.
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
        guard player.play() else { return }
        isPlaying = true
        startTicking()
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
                    // `pause()` cancels this task, but it may already be past
                    // the cancellation check — without this guard a pause could
                    // be mistaken for the end of the file and lose the
                    // listener's place.
                    guard self.isPlaying else { return }
                    // Stopped mid-file means something stopped it underneath
                    // us — an interruption whose notification hasn't landed
                    // yet. Hold the place; the observer settles the state.
                    // (At a genuine end AVAudioPlayer rewinds to 0.)
                    let midFile = player.currentTime > 0.05
                        && player.currentTime < player.duration - 0.1
                    if midFile {
                        self.pause()
                        return
                    }
                    // Reached the end. Let go of the file entirely rather than
                    // just rewinding: a loaded-but-idle player would keep every
                    // waveform on screen drawn as nought-percent-played, when
                    // what it should show is a finished memo at full strength.
                    self.stop()
                    return
                }
            }
        }
    }
}
