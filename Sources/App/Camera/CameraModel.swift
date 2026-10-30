import AVFoundation
import CoreMotion
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
    /// Debug builds show it on the viewfinder: device, field of view, photo size.
    private(set) var formatSummary = ""
    /// The scene is dark: shots gather frames after the press (the moon badge).
    private(set) var isLowLight = false
    /// A dark shot is still being gathered: "Hold still".
    private(set) var isHoldingStill = false
    /// Held sideways, from the accelerometer (no permission needed).
    private(set) var tilt: CameraTilt = .upright
    var isLandscape: Bool { tilt.isLandscape }

    /// Both cameras at once, sent as one photo (`DualCameraEngine`). Never
    /// remembered: the camera always opens on one.
    private(set) var isDual = false
    /// Which camera fills the frame; the other is the inset.
    private(set) var dualMainIsBack = true
    /// Where the inset sits, as the portrait screen shows it.
    private(set) var dualCorner: DualShotLayout.Corner = .topLeading
    /// Why Both turned itself off; cleared after a few seconds.
    private(set) var dualNotice: DualNotice?
    var supportsBothCameras: Bool { DualCameraEngine.isSupported }

    enum DualNotice: Equatable {
        case tooWarm
        case unavailable
    }

    @ObservationIgnored var onCapture: (CameraShot) -> Void = { _ in }
    /// Made on first use: `@State` builds a throwaway model each time the view
    /// is re-created. Dropped when Both takes over, and the other way round.
    @ObservationIgnored private var singleEngine: CameraEngine?
    @ObservationIgnored private var dualEngine: DualCameraEngine?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var dualListener: Task<Void, Never>?
    @ObservationIgnored private var loadedSettings = false
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Too warm mid-shot: back to one camera once the shot is in.
    @ObservationIgnored private var leaveDualAfterCapture = false
    /// The screen has gone: a switch still under way mustn't start a camera.
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var pinchStart: CGFloat?
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored private let motion = CMMotionManager()

    init(store: SharedStore = .shared) {
        self.store = store
    }

    var session: AVCaptureSession { engine.session }

    /// The two previews while Both runs.
    var dualPreviews: (back: AVCaptureVideoPreviewLayer, front: AVCaptureVideoPreviewLayer)? {
        dualEngine.map { ($0.backPreview, $0.frontPreview) }
    }

    var canShoot: Bool { state == .running && !isCapturing && !isInterrupted }

    private var engine: CameraEngine {
        if let singleEngine { return singleEngine }
        let engine = CameraEngine()
        singleEngine = engine
        // Queued ahead of `start`, so the Camera Control's picker opens on it.
        engine.setTimer(timer)
        listener = Task { [weak self, events = engine.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        return engine
    }

    private func makeDualEngine() -> DualCameraEngine {
        if let dualEngine { return dualEngine }
        let engine = DualCameraEngine()
        dualEngine = engine
        dualListener = Task { [weak self, events = engine.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        return engine
    }

    func start() async {
        isStopped = false
        if !loadedSettings {
            loadedSettings = true
            let saved = store.cameraSettings
            position = saved.frontCamera ? .front : .back
            preferredFlash = saved.flash
            timer = saved.timer
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default:
            state = .denied
            return
        }
        startTiltUpdates()
        await startEngine()
    }

    /// Both if chosen, falling back to one camera with a notice.
    private func startEngine() async {
        guard !isStopped else { return }
        if isDual {
            let dual = makeDualEngine()
            if await dual.start() {
                state = .running
                if isStopped { dual.stop() }
                return
            }
            await dropDualEngine()
            showDualNotice(.unavailable)
        }
        state = await engine.start(position: position) ? .running : .failed
        if isStopped { singleEngine?.stop() }
    }

    func stop() {
        isStopped = true
        cancelCountdown(announce: false)
        motion.stopAccelerometerUpdates()
        singleEngine?.stop()
        dualEngine?.stop()
    }

    // MARK: - Both cameras

    func toggleBothCameras() {
        guard state == .running, countdown == nil, !isCapturing, !isSwitching else { return }
        Task { await switchTo(dual: !isDual) }
    }

    /// One session lets go of the cameras before the other starts.
    private func switchTo(dual: Bool) async {
        isSwitching = true
        defer { isSwitching = false }
        state = .starting
        if dual {
            dualNotice = nil
            // Made first: the preview swaps to its layers as `isDual` flips.
            _ = makeDualEngine()
            isDual = true
            isLowLight = false
            lenses = nil
            zoom = 1
            await singleEngine?.halt()
            listener?.cancel()
            singleEngine = nil
        } else {
            await dropDualEngine()
        }
        await startEngine()
        saveSettings()
    }

    private func dropDualEngine() async {
        await dualEngine?.halt()
        _ = engine
        isDual = false
        dualListener?.cancel()
        dualEngine = nil
    }

    private func showDualNotice(_ notice: DualNotice) {
        dualNotice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dualNotice = nil }
        }
        let text = notice == .tooWarm
            ? String(localized: "Back to one camera: the iPhone is warm")
            : String(localized: "Both cameras couldn't start")
        AccessibilityNotification.Announcement(text).post()
    }

    func swapDualCameras() {
        guard isDual, !isCapturing else { return }
        dualMainIsBack.toggle()
    }

    func moveDualInset(to corner: DualShotLayout.Corner) {
        dualCorner = corner
    }

    private func startTiltUpdates() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.2
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.acceleration else { return }
            MainActor.assumeIsolated { self?.tilted(x: g.x, y: g.y, z: g.z) }
        }
    }

    private func tilted(x: Double, y: Double, z: Double) {
        let wasLandscape = isLandscape
        tilt = CameraTilt.reading(x: x, y: y, z: z, was: tilt)
        let landscape = isLandscape
        guard landscape != wasLandscape else { return }
        // Like the system camera: turning the phone re-frames a selfie, over
        // whatever the button or a pinch had chosen.
        if let lenses, lenses.selfieNarrowZoom != nil {
            selectLens(lenses.openingZoom(landscape: landscape))
        }
    }

    private func handle(_ event: DualCameraEngine.Event) {
        switch event {
        case let .ready(flashModes, format):
            formatSummary = format
            self.flashModes = flashModes
        case let .interrupted(on):
            isInterrupted = on
            if on { cancelCountdown(announce: false) }
        case .willCapture:
            shutterCount += 1
        case .tooWarm:
            guard isDual, !isSwitching else { return }
            cancelCountdown(announce: false)
            showDualNotice(.tooWarm)
            if isCapturing {
                leaveDualAfterCapture = true
            } else {
                Task { await switchTo(dual: false) }
            }
        }
    }

    private func handle(_ event: CameraEngine.Event) {
        switch event {
        case let .configured(position, lenses, zoom, flashModes, format):
            formatSummary = format
            self.position = position
            self.lenses = lenses
            self.zoom = zoom
            self.flashModes = flashModes
            saveSettings()
            // The engine opens upright; a selfie started sideways goes wide.
            if isLandscape, lenses.selfieNarrowZoom != nil {
                selectLens(lenses.openingZoom(landscape: true))
            }
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
        case .didCapture:
            isHoldingStill = false
        case let .lowLight(dark):
            isLowLight = dark
        }
    }

    // MARK: - Controls

    func flip() {
        guard state == .running, countdown == nil, !isCapturing else { return }
        if isDual { return swapDualCameras() }
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

    var isSelfieWide: Bool { lenses?.isSelfieWide(zoom) ?? false }

    func toggleSelfieWidth() {
        guard let lenses else { return }
        selectLens(lenses.selfieToggled(from: zoom))
    }

    func pinchChanged(_ scale: CGFloat) {
        if isDual {
            // Only the back camera zooms, and only while it fills the frame.
            guard dualMainIsBack, let dualEngine else { return }
            let start = pinchStart ?? zoom
            pinchStart = start
            zoom = min(max(start * scale, 1), DualCameraEngine.maxZoom)
            return dualEngine.setZoom(zoom)
        }
        guard let lenses else { return }
        let start = pinchStart ?? zoom
        pinchStart = start
        zoom = lenses.clamped(start * scale)
        engine.setZoom(zoom)
    }

    func pinchEnded() {
        pinchStart = nil
    }

    /// `devicePoint` in the main camera's 0…1 space.
    func focus(at devicePoint: CGPoint) {
        if isDual {
            dualEngine?.focus(at: devicePoint, back: dualMainIsBack)
        } else {
            engine.focus(at: devicePoint)
        }
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
        if isLowLight {
            isHoldingStill = true
            AccessibilityNotification.Announcement(String(localized: "Hold still")).post()
        }
        Task {
            defer {
                isCapturing = false
                isHoldingStill = false
                if leaveDualAfterCapture {
                    leaveDualAfterCapture = false
                    Task { await switchTo(dual: false) }
                }
            }
            do {
                if isDual, let dualEngine {
                    onCapture(.both(try await captureBoth(dualEngine)))
                } else {
                    let data = try await engine.capture(flash: flash, rotationAngle: tilt.captureAngle(frontCamera: position == .front))
                    guard let image = UIImage(data: data) else { throw CameraEngine.CaptureError.noData }
                    onCapture(.photo(image))
                }
            } catch {
                captureFailed = true
            }
        }
    }

    /// Left apart for the composer, where the inset can still be moved.
    private func captureBoth(_ dual: DualCameraEngine) async throws -> DualShot {
        let mainIsBack = dualMainIsBack
        let placement = DualShotLayout.Placement(dualCorner.inPhoto(tilt: tilt))
        let shots = try await dual.capture(flash: flash, tilt: tilt, mainIsBack: mainIsBack)
        let (main, inset) = mainIsBack ? (shots.back, shots.front) : (shots.front, shots.back)
        let shot = await Task.detached(priority: .userInitiated) {
            DualShotComposer.prepare(main: main, inset: inset, placement: placement)
        }.value
        guard let shot else { throw CameraEngine.CaptureError.noData }
        return shot
    }
}
