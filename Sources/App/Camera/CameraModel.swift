import AVFoundation
import Observation
import SwiftUI

/// The camera screen's state: what the engine reported, the user's choices,
/// and the self-timer's countdown.
@MainActor
@Observable
final class CameraModel {
    enum State: Equatable {
        case starting
        /// The user said no to the camera. Recoverable only in Settings.
        case denied
        case running
        case failed
    }

    private(set) var state: State = .starting
    private(set) var position: AVCaptureDevice.Position = .front
    private(set) var lenses: CameraLensPlan?
    private(set) var zoom: CGFloat = 1
    private(set) var flashModes: [CameraFlash] = []
    /// The remembered choice; `flash` is what this camera can actually do.
    private(set) var preferredFlash: CameraFlash = .auto
    var flash: CameraFlash { preferredFlash.resolved(in: flashModes) }
    private(set) var timer: CameraTimer = .off
    /// Seconds left on the self-timer, or `nil` when none is running.
    private(set) var countdown: Int?
    private(set) var isCapturing = false
    /// Another app, a call or Split View has the camera.
    private(set) var isInterrupted = false
    /// The Camera Control's overlay is up.
    private(set) var controlsFullscreen = false
    /// Bumped as the sensor fires, for the shutter blink.
    private(set) var shutterCount = 0
    private(set) var captureFailed = false

    @ObservationIgnored var onCapture: (UIImage) -> Void = { _ in }
    /// Lazy: `@State` builds a throwaway model each time the view is re-created.
    @ObservationIgnored private lazy var engine = CameraEngine()
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var pinchStart: CGFloat?
    @ObservationIgnored private let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    var session: AVCaptureSession { engine.session }

    var canShoot: Bool { state == .running && !isCapturing && !isInterrupted }

    func start() async {
        if listener == nil {
            let saved = store.cameraSettings
            position = saved.frontCamera ? .front : .back
            preferredFlash = saved.flash
            timer = saved.timer
            // Queued ahead of `start`, so the Camera Control's picker opens on it.
            engine.setTimer(timer)
            // Ends on its own when the engine (and its stream) goes.
            listener = Task { [weak self, events = engine.events] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default:
            state = .denied
            return
        }
        state = await engine.start(position: position) ? .running : .failed
    }

    func stop() {
        cancelCountdown(announce: false)
        engine.stop()
    }

    private func handle(_ event: CameraEngine.Event) {
        switch event {
        case let .configured(position, lenses, zoom, flashModes):
            self.position = position
            self.lenses = lenses
            self.zoom = zoom
            self.flashModes = flashModes
            saveSettings()
        case let .zoomChanged(zoom):
            self.zoom = zoom
        case let .timerPicked(timer):
            self.timer = timer
            saveSettings()
        case let .controlsFullscreen(on):
            withAnimation(.smooth(duration: 0.2)) { controlsFullscreen = on }
        case let .interrupted(on):
            isInterrupted = on
            if on { cancelCountdown(announce: false) }
        case .willCapture:
            shutterCount += 1
        }
    }

    // MARK: - Controls

    func flip() {
        guard state == .running, countdown == nil, !isCapturing else { return }
        engine.switchCamera(to: position == .front ? .back : .front)
    }

    func cycleFlash() {
        preferredFlash = flash.next(in: flashModes)
        saveSettings()
    }

    func cycleTimer() {
        timer = timer.next
        engine.setTimer(timer)
        saveSettings()
    }

    /// The position is saved from `.configured`, so a switch that failed isn't remembered.
    private func saveSettings() {
        store.cameraSettings = CameraSettings(frontCamera: position == .front,
                                              flash: preferredFlash, timer: timer)
    }

    func selectLens(_ preset: CGFloat) {
        zoom = preset
        engine.setZoom(preset)
    }

    func pinchChanged(_ scale: CGFloat) {
        guard let lenses else { return }
        let start = pinchStart ?? zoom
        pinchStart = start
        zoom = lenses.clamped(start * scale)
        engine.setZoom(zoom)
    }

    func pinchEnded() {
        pinchStart = nil
    }

    func focus(at devicePoint: CGPoint) {
        engine.focus(at: devicePoint)
    }

    // MARK: - Shutter

    /// The on-screen button, the volume buttons, AirPods and the Camera Control
    /// all land here. With a timer set, a second press cancels it.
    func shutter() {
        if countdown != nil { return cancelCountdown(announce: true) }
        guard canShoot else { return }
        guard timer != .off else { return capture() }

        AccessibilityNotification.Announcement(
            String(localized: "Taking the photo in \(timer.rawValue) seconds")).post()
        countdownTask = Task {
            for remaining in stride(from: timer.rawValue, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            capture()
        }
    }

    private func cancelCountdown(announce: Bool) {
        guard countdownTask != nil else { return }
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        if announce {
            AccessibilityNotification.Announcement(String(localized: "Timer cancelled")).post()
        }
    }

    private func capture() {
        guard canShoot else { return }
        isCapturing = true
        captureFailed = false
        Task {
            defer { isCapturing = false }
            do {
                let data = try await engine.capture(flash: flash)
                guard let image = UIImage(data: data) else { throw CameraEngine.CaptureError.noData }
                onCapture(image)
            } catch {
                captureFailed = true
            }
        }
    }
}
