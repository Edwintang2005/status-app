import AVFoundation
import os

/// Everything AVFoundation for the moment camera. All capture state is touched
/// only on `queue` (`startRunning` blocks, and the session isn't thread-safe);
/// the UI hears back through `events`.
final class CameraEngine: NSObject, @unchecked Sendable {
    enum Event: Sendable {
        case configured(position: AVCaptureDevice.Position, lenses: CameraLensPlan,
                        zoom: CGFloat, flashModes: [CameraFlash])
        /// The Camera Control moved the zoom (raw factor).
        case zoomChanged(CGFloat)
        case timerPicked(CameraTimer)
        /// The Camera Control's overlay is up: the app's own controls step aside.
        case controlsFullscreen(Bool)
        case interrupted(Bool)
        case willCapture
        /// The phone turned between upright and sideways (the UI itself never rotates).
        case orientationChanged(landscape: Bool)
    }

    enum CaptureError: Error { case notRunning, noData }

    let session = AVCaptureSession()
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let queue = DispatchQueue(label: "\(AppConfig.appGroupID).camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var lenses: CameraLensPlan?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var isLandscape = false
    private var captures: [Int64: PhotoCapture] = [:]
    /// `AVCaptureIndexPicker` (iOS 18), kept to mirror the on-screen timer.
    private var timerPicker: AnyObject?
    private var timer: CameraTimer = .off
    private var wantsRunning = false
    private var configured = false
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "Camera")

    /// False on the Simulator, which has no camera.
    static let isAvailable = AVCaptureDevice.default(for: .video) != nil

    override init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                               object: session, queue: nil) { [weak self] _ in
                self?.continuation.yield(.interrupted(true))
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                               object: session, queue: nil) { [weak self] _ in
                self?.continuation.yield(.interrupted(false))
            },
            // A media-services reset stops the session; the system camera restarts.
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                               object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    if self.wantsRunning, !self.session.isRunning { self.session.startRunning() }
                }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        continuation.finish()
    }

    // MARK: - Running

    /// Configures on first use and starts the session; false if no camera could be opened.
    func start(position: AVCaptureDevice.Position) async -> Bool {
        await withCheckedContinuation { done in
            queue.async {
                self.wantsRunning = true
                if !self.configured {
                    // Before the controls go in: they stay inactive without a delegate.
                    if #available(iOS 18.0, *), self.session.supportsControls {
                        self.session.setControlsDelegate(self, queue: self.queue)
                    }
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    if self.session.canAddOutput(self.photoOutput) {
                        self.session.addOutput(self.photoOutput)
                    }
                    // The remembered side, else the other one.
                    self.configured = self.useDevice(at: position)
                        || self.useDevice(at: position == .front ? .back : .front)
                    self.session.commitConfiguration()
                }
                guard self.configured else { return done.resume(returning: false) }
                if !self.session.isRunning { self.session.startRunning() }
                done.resume(returning: true)
            }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func switchCamera(to position: AVCaptureDevice.Position) {
        queue.async {
            self.session.beginConfiguration()
            _ = self.useDevice(at: position)
            self.session.commitConfiguration()
        }
    }

    /// Must run inside a configuration block on `queue`.
    private func useDevice(at position: AVCaptureDevice.Position) -> Bool {
        guard let device = Self.device(at: position),
              let newInput = try? AVCaptureDeviceInput(device: device) else {
            log.error("No camera at position \(position.rawValue)")
            return false
        }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            return false
        }
        session.addInput(newInput)
        input = newInput

        // Multi-frame fusion on every shot: the nearest thing to Night mode a
        // third-party app can ask for. No bigger than a 12 MP frame, since
        // `MomentStore` keeps 2048 px anyway and 48 MP slows each capture.
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let dims = device.activeFormat.supportedMaxPhotoDimensions
            .sorted(by: { $0.width * $0.height < $1.width * $1.height })
            .first(where: { max($0.width, $0.height) >= 3000 })
            ?? device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dims
        }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }

        var multiplier: CGFloat?
        if #available(iOS 18.0, *) { multiplier = device.displayVideoZoomFactorMultiplier }
        let plan = CameraLensPlan(
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) },
            hasUltraWide: device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera },
            minAvailable: device.minAvailableVideoZoomFactor,
            maxAvailable: device.maxAvailableVideoZoomFactor,
            systemMultiplier: multiplier,
            offersTwoTimes: position == .back,
            isSelfie: position == .front)
        lenses = plan
        let zoom = plan.openingZoom(landscape: isLandscape)
        configure(device) {
            $0.videoZoomFactor = zoom
            if $0.isFocusModeSupported(.continuousAutoFocus) { $0.focusMode = .continuousAutoFocus }
            if $0.isExposureModeSupported(.continuousAutoExposure) { $0.exposureMode = .continuousAutoExposure }
        }
        observeRotation(of: device)
        if #available(iOS 18.0, *) { installControls(for: device) }

        let flashModes = photoOutput.supportedFlashModes.compactMap { mode -> CameraFlash? in
            switch mode {
            case .auto: .auto
            case .on: .on
            case .off: .off
            @unknown default: nil
            }
        }
        continuation.yield(.configured(position: position, lenses: plan,
                                       zoom: zoom, flashModes: flashModes))
        return true
    }

    /// Gravity, not the interface: the app is portrait-only. Lying flat keeps
    /// the last reading.
    private func observeRotation(of device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            let landscape = coordinator.videoRotationAngleForHorizonLevelCapture
                .truncatingRemainder(dividingBy: 180) == 0
            guard let self else { return }
            self.queue.async {
                guard landscape != self.isLandscape else { return }
                self.isLandscape = landscape
                self.continuation.yield(.orientationChanged(landscape: landscape))
            }
        }
    }

    /// The virtual multi-lens camera where there is one, so zoom crosses lenses
    /// the way the system camera does.
    private static func device(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) { return device }
        }
        return nil
    }

    // MARK: - Zoom, focus, timer

    /// Set outright, never ramped: a lens button cuts straight to its lens,
    /// as the system camera does, and a pinch sets it every frame.
    func setZoom(_ zoom: CGFloat) {
        queue.async {
            guard let device = self.input?.device, let lenses = self.lenses else { return }
            let target = lenses.clamped(zoom)
            self.configure(device) { $0.videoZoomFactor = target }
        }
    }

    /// `point` in the device's 0…1 space (`captureDevicePointConverted`).
    func focus(at point: CGPoint) {
        queue.async {
            guard let device = self.input?.device else { return }
            self.configure(device) {
                if $0.isFocusPointOfInterestSupported, $0.isFocusModeSupported(.continuousAutoFocus) {
                    $0.focusPointOfInterest = point
                    $0.focusMode = .continuousAutoFocus
                }
                if $0.isExposurePointOfInterestSupported, $0.isExposureModeSupported(.continuousAutoExposure) {
                    $0.exposurePointOfInterest = point
                    $0.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    /// Keeps the Camera Control's timer picker on the on-screen choice.
    func setTimer(_ timer: CameraTimer) {
        queue.async {
            self.timer = timer
            if #available(iOS 18.0, *), let picker = self.timerPicker as? AVCaptureIndexPicker {
                picker.selectedIndex = timer.index
            }
        }
    }

    private func configure(_ device: AVCaptureDevice, _ change: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            change(device)
            device.unlockForConfiguration()
        } catch {
            log.error("Couldn't configure the camera: \(error.localizedDescription)")
        }
    }

    @available(iOS 18.0, *)
    private func installControls(for device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        session.controls.forEach(session.removeControl)
        let zoom = AVCaptureSystemZoomSlider(device: device) { [weak self] factor in
            self?.continuation.yield(.zoomChanged(factor))
        }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device)
        let picker = AVCaptureIndexPicker(
            String(localized: "Timer"), symbolName: "timer",
            localizedIndexTitles: CameraTimer.allCases.map(\.title))
        picker.selectedIndex = timer.index
        picker.setActionQueue(queue) { [weak self] index in
            guard let self else { return }
            self.timer = CameraTimer(index: index)
            self.continuation.yield(.timerPicked(self.timer))
        }
        timerPicker = picker
        for control in [zoom, exposure, picker] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    // MARK: - Capture

    /// The shot's encoded bytes (HEIC or JPEG, orientation in its metadata).
    func capture(flash: CameraFlash) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            queue.async {
                guard self.session.isRunning,
                      let connection = self.photoOutput.connection(with: .video) else {
                    return done.resume(throwing: CaptureError.notRunning)
                }
                // The UI is portrait-only; the coordinator still knows how the
                // phone is held, so a sideways shot comes out level.
                if let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture,
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .quality
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                let mode: AVCaptureDevice.FlashMode = switch flash {
                case .auto: .auto
                case .on: .on
                case .off: .off
                }
                if self.photoOutput.supportedFlashModes.contains(mode) { settings.flashMode = mode }

                let id = settings.uniqueID
                let capture = PhotoCapture(
                    done: done,
                    willCapture: { [continuation = self.continuation] in continuation.yield(.willCapture) },
                    finished: { self.queue.async { self.captures[id] = nil } })
                // The output doesn't keep its delegate alive.
                self.captures[id] = capture
                self.photoOutput.capturePhoto(with: settings, delegate: capture)
            }
        }
    }
}

@available(iOS 18.0, *)
extension CameraEngine: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        continuation.yield(.controlsFullscreen(true))
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        continuation.yield(.controlsFullscreen(false))
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        continuation.yield(.controlsFullscreen(false))
    }
}

extension CameraTimer {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .three: String(localized: "3s")
        case .ten: String(localized: "10s")
        }
    }
}

/// One shot's delegate. Resumes its continuation exactly once, whichever
/// callback gets there first.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let done: OSAllocatedUnfairLock<CheckedContinuation<Data, Error>?>
    private let willCapture: @Sendable () -> Void
    private let finished: @Sendable () -> Void

    init(done: CheckedContinuation<Data, Error>,
         willCapture: @escaping @Sendable () -> Void,
         finished: @escaping @Sendable () -> Void) {
        self.done = OSAllocatedUnfairLock(initialState: done)
        self.willCapture = willCapture
        self.finished = finished
    }

    private func resume(_ result: Result<Data, Error>) {
        done.withLock { $0.take() }?.resume(with: result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let data = photo.fileDataRepresentation() {
            resume(.success(data))
        } else {
            resume(.failure(error ?? CameraEngine.CaptureError.noData))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        resume(.failure(error ?? CameraEngine.CaptureError.noData))
        finished()
    }
}
