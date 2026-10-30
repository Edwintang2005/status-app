import AVFoundation
import os

/// Both cameras at once (`AVCaptureMultiCamSession`): a live preview of each and
/// one photo from each per shot, combined by `DualShotComposer`. As in
/// `CameraEngine`, capture state is touched only on `queue`. Plain wide-angle
/// cameras on both sides: a virtual multi-lens camera costs too much beside another.
final class DualCameraEngine: NSObject, @unchecked Sendable {
    enum Event: Sendable {
        case ready(flashModes: [CameraFlash], format: String)
        case interrupted(Bool)
        case willCapture
        /// Two cameras have made the phone hot: the model goes back to one.
        case tooWarm
    }

    struct Shots: Sendable {
        var back: Data
        var front: Data
    }

    /// Every iPhone that runs iOS 17 has the A12 or later it needs; checked anyway.
    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }
    static let maxZoom: CGFloat = 5

    let session: AVCaptureMultiCamSession
    /// Made unconnected; `configure` connects each to its camera.
    let backPreview: AVCaptureVideoPreviewLayer
    let frontPreview: AVCaptureVideoPreviewLayer
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let queue = DispatchQueue(label: "\(AppConfig.appGroupID).camera.dual")
    private let backOutput = AVCapturePhotoOutput()
    private let frontOutput = AVCapturePhotoOutput()
    private var back: AVCaptureDevice?
    private var front: AVCaptureDevice?
    private var configured = false
    private var wantsRunning = false
    private var warned = false
    private var captures: [Int64: PhotoCapture] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pressure: [NSKeyValueObservation] = []
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "DualCamera")

    override init() {
        let session = AVCaptureMultiCamSession()
        self.session = session
        backPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        frontPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        backPreview.videoGravity = .resizeAspectFill
        frontPreview.videoGravity = .resizeAspectFill
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
        pressure.forEach { $0.invalidate() }
        continuation.finish()
    }

    // MARK: - Running

    /// Configures on first use and starts both cameras; false if they can't run together.
    func start() async -> Bool {
        await withCheckedContinuation { done in
            queue.async {
                self.wantsRunning = true
                if !self.configured { self.configured = self.configure() }
                guard self.configured else { return done.resume(returning: false) }
                if !self.session.isRunning { self.session.startRunning() }
                done.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// Returns once the cameras are released, for the single camera to take over.
    func halt() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopOnQueue()
                done.resume()
            }
        }
    }

    private func stopOnQueue() {
        wantsRunning = false
        if session.isRunning { session.stopRunning() }
    }

    /// On `queue`. Formats step down together until the hardware can carry both.
    private func configure() -> Bool {
        guard Self.isSupported,
              let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            return false
        }
        let backFormats = Self.formats(for: back)
        let frontFormats = Self.formats(for: front)
        guard !backFormats.isEmpty, !frontFormats.isEmpty else {
            log.error("No formats both cameras can share")
            return false
        }

        session.beginConfiguration()
        let connected = connect(back, to: backOutput, preview: backPreview, mirrored: false)
            && connect(front, to: frontOutput, preview: frontPreview, mirrored: true)
        session.commitConfiguration()
        guard connected else {
            log.error("Couldn't connect both cameras")
            return false
        }
        for step in 0..<max(backFormats.count, frontFormats.count) {
            session.beginConfiguration()
            use(backFormats[min(step, backFormats.count - 1)], on: back)
            use(frontFormats[min(step, frontFormats.count - 1)], on: front)
            session.commitConfiguration()
            if session.hardwareCost <= 1 { break }
        }
        guard session.hardwareCost <= 1 else {
            log.error("Both cameras cost \(self.session.hardwareCost) even at the smallest formats")
            return false
        }

        for (output, device) in [(backOutput, back), (frontOutput, front)] {
            output.maxPhotoQualityPrioritization = .balanced
            if let dims = Self.photoDimensions(device.activeFormat) { output.maxPhotoDimensions = dims }
        }
        self.back = back
        self.front = front
        // `.initial`: a phone already hot when Both is chosen hears so at once.
        pressure = [back, front].map { device in
            device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                let level = device.systemPressureState.level
                guard level == .serious || level == .critical || level == .shutdown, let self else { return }
                self.queue.async { self.warnWarm() }
            }
        }

        let flashModes = backOutput.supportedFlashModes.compactMap { mode -> CameraFlash? in
            switch mode {
            case .auto: .auto
            case .on: .on
            case .off: .off
            @unknown default: nil
            }
        }
        let format = [backOutput, frontOutput]
            .map { "\($0.maxPhotoDimensions.width)×\($0.maxPhotoDimensions.height)" }
            .joined(separator: " + ") + " · cost \(String(format: "%.2f", session.hardwareCost))"
        continuation.yield(.ready(flashModes: flashModes, format: format))
        return true
    }

    private func warnWarm() {
        guard !warned else { return }
        warned = true
        continuation.yield(.tooWarm)
    }

    /// Must run inside a configuration block on `queue`. A multi-cam session
    /// wires nothing itself: photo output and preview each get a connection.
    private func connect(_ device: AVCaptureDevice, to output: AVCapturePhotoOutput,
                         preview: AVCaptureVideoPreviewLayer, mirrored: Bool) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)
        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first,
              session.canAddOutput(output) else { return false }
        session.addOutputWithNoConnections(output)
        let photo = AVCaptureConnection(inputPorts: [port], output: output)
        let view = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
        guard session.canAddConnection(photo) else { return false }
        session.addConnection(photo)
        guard session.canAddConnection(view) else { return false }
        session.addConnection(view)
        // The app is portrait-only; a selfie preview reads like a mirror, as in the single camera.
        if view.isVideoRotationAngleSupported(90) { view.videoRotationAngle = 90 }
        if mirrored, view.isVideoMirroringSupported {
            view.automaticallyAdjustsVideoMirroring = false
            view.isVideoMirrored = true
        }
        return true
    }

    private func use(_ format: AVCaptureDevice.Format, on device: AVCaptureDevice) {
        configure(device) { $0.activeFormat = format }
    }

    /// 4:3, multi-cam capable, no wider than 1920 where there's a choice (cost
    /// grows with it), largest first — each later one a cheaper step down.
    private static func formats(for device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        func dims(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func largestPhoto(_ format: AVCaptureDevice.Format) -> Int32 {
            format.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
        }
        let shared = device.formats.filter { format in
            let size = dims(format)
            return format.isMultiCamSupported && size.width * 3 == size.height * 4
        }
        let modest = shared.filter { dims($0).width <= 1920 }
        return (modest.isEmpty ? shared : modest).sorted {
            (dims($0).width * dims($0).height, largestPhoto($0)) > (dims($1).width * dims($1).height, largestPhoto($1))
        }
    }

    /// The smallest photo still as large as a moment keeps (`MomentStore.fullMaxDimension`):
    /// the inset needs far less, and a smaller capture is quicker.
    private static func photoDimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        let sizes = format.supportedMaxPhotoDimensions.sorted { $0.width * $0.height < $1.width * $1.height }
        return sizes.first { CGFloat(max($0.width, $0.height)) >= MomentStore.fullMaxDimension } ?? sizes.last
    }

    // MARK: - Zoom and focus

    /// The back camera only: the front one's wide-angle has nowhere to zoom.
    func setZoom(_ zoom: CGFloat) {
        queue.async {
            guard let back = self.back else { return }
            let upper = min(back.maxAvailableVideoZoomFactor, Self.maxZoom)
            self.configure(back) { $0.videoZoomFactor = min(max(zoom, back.minAvailableVideoZoomFactor), upper) }
        }
    }

    /// `point` in the device's 0…1 space (`captureDevicePointConverted`).
    func focus(at point: CGPoint, back onBack: Bool) {
        queue.async {
            guard let device = onBack ? self.back : self.front else { return }
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

    private func configure(_ device: AVCaptureDevice, _ change: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            change(device)
            device.unlockForConfiguration()
        } catch {
            log.error("Couldn't configure the camera: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture

    /// One photo from each camera, fired together. Flash lights only the back
    /// shot; the shutter blink follows the camera filling the frame.
    func capture(flash: CameraFlash, tilt: CameraTilt, mainIsBack: Bool) async throws -> Shots {
        async let back = shoot(back: true, flash: flash,
                               angle: tilt.captureAngle(frontCamera: false), announces: mainIsBack)
        async let front = shoot(back: false, flash: .off,
                                angle: tilt.captureAngle(frontCamera: true), announces: !mainIsBack)
        return try await Shots(back: back, front: front)
    }

    private func shoot(back: Bool, flash: CameraFlash,
                       angle: CGFloat, announces: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            queue.async {
                let output = back ? self.backOutput : self.frontOutput
                guard self.session.isRunning, let connection = output.connection(with: .video) else {
                    return done.resume(throwing: CameraEngine.CaptureError.notRunning)
                }
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                settings.maxPhotoDimensions = output.maxPhotoDimensions
                let mode: AVCaptureDevice.FlashMode = switch flash {
                case .auto: .auto
                case .on: .on
                case .off: .off
                }
                if output.supportedFlashModes.contains(mode) { settings.flashMode = mode }

                let id = settings.uniqueID
                let capture = PhotoCapture(
                    done: done,
                    willCapture: { [continuation = self.continuation] in
                        if announces { continuation.yield(.willCapture) }
                    },
                    didCapture: {},
                    finished: { self.queue.async { self.captures[id] = nil } })
                self.captures[id] = capture
                output.capturePhoto(with: settings, delegate: capture)
            }
        }
    }
}
