import Foundation

/// The camera's lens buttons and zoom limits, worked out from what the device
/// reports — pure, so the tests reach it without a camera.
struct CameraLensPlan: Equatable, Sendable {
    /// Raw `videoZoomFactor` × this is the number shown: a virtual camera
    /// whose factor 1 is the ultra wide shows it as 0.5×.
    var displayMultiplier: CGFloat
    /// Raw zoom factors for the lens buttons, ascending. One means no row.
    var presets: [CGFloat]
    var minZoom: CGFloat
    var maxZoom: CGFloat
    /// Where the camera opens: the wide lens, shown as 1×.
    var defaultZoom: CGFloat
    /// The front camera's upright framing, cropped in from its full sensor;
    /// `nil` on the back camera. `minZoom` is the wide selfie.
    var selfieNarrowZoom: CGFloat?

    /// The system camera goes further, but past this a square crop is mush.
    static let maxDisplayZoom: CGFloat = 15
    /// The system camera's upright selfie: 7 MP of the 12 MP front sensor
    /// (iPhone 11 onwards), √(12/7) in linear zoom.
    static let selfieCrop: CGFloat = 1.31

    /// - Parameters:
    ///   - switchOverFactors: `virtualDeviceSwitchOverVideoZoomFactors`, the
    ///     raw factors where the next lens takes over.
    ///   - systemMultiplier: `displayVideoZoomFactorMultiplier` (iOS 18), else
    ///     derived from the first switch-over.
    ///   - offersTwoTimes: add a 2× crop where no lens sits (the back camera).
    ///   - isSelfie: the front camera, which frames like the system camera:
    ///     cropped upright, its full width sideways or on request.
    init(switchOverFactors: [CGFloat],
         hasUltraWide: Bool,
         minAvailable: CGFloat,
         maxAvailable: CGFloat,
         systemMultiplier: CGFloat? = nil,
         offersTwoTimes: Bool,
         isSelfie: Bool = false) {
        let wide = hasUltraWide ? (switchOverFactors.first ?? 1) : 1
        let multiplier = systemMultiplier ?? (wide > 0 ? 1 / wide : 1)
        let lower = max(minAvailable, 1)
        let upper = max(lower, min(maxAvailable, Self.maxDisplayZoom / multiplier))

        var presets = ([1] + switchOverFactors).filter { $0 >= lower && $0 <= upper }
        let two = 2 / multiplier
        if offersTwoTimes, two <= upper,
           !presets.contains(where: { abs($0 - two) / two < 0.05 }) {
            presets.append(two)
        }
        presets = presets.sorted()

        displayMultiplier = multiplier
        self.presets = presets.isEmpty ? [lower] : presets
        minZoom = lower
        maxZoom = upper
        defaultZoom = min(max(wide, lower), upper)
        selfieNarrowZoom = isSelfie && upper >= Self.selfieCrop ? Self.selfieCrop : nil
    }

    /// Where the camera opens, and where the front camera returns whenever the
    /// phone turns between upright and sideways.
    func openingZoom(landscape: Bool) -> CGFloat {
        guard let selfieNarrowZoom else { return defaultZoom }
        return landscape ? minZoom : selfieNarrowZoom
    }

    /// Nearer the full sensor than the upright crop (a pinch lands anywhere).
    func isSelfieWide(_ zoom: CGFloat) -> Bool {
        guard let selfieNarrowZoom else { return false }
        return zoom < (minZoom + selfieNarrowZoom) / 2
    }

    /// The front camera's expand button: wide ↔ the upright crop.
    func selfieToggled(from zoom: CGFloat) -> CGFloat {
        guard let selfieNarrowZoom else { return zoom }
        return isSelfieWide(zoom) ? selfieNarrowZoom : minZoom
    }

    func clamped(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minZoom), maxZoom)
    }

    func displayed(_ zoom: CGFloat) -> CGFloat {
        zoom * displayMultiplier
    }

    /// The button that lights up: the widest lens at or below the current zoom,
    /// as the system camera does between presets.
    func activePreset(for zoom: CGFloat) -> CGFloat? {
        presets.last { $0 <= zoom * 1.01 } ?? presets.first
    }

    /// "0.5×", "1×", "2.4×" — whole numbers drop the decimal.
    static func label(_ displayed: CGFloat) -> String {
        let rounded = (displayed * 10).rounded() / 10
        return Double(rounded).formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}

/// How the phone is held, from gravity: the app is portrait-only, and Portrait
/// Orientation Lock freezes both the interface's reading and the capture
/// rotation coordinator's.
enum CameraTilt: Equatable, Sendable {
    case upright, upsideDown
    /// Top of the phone to the left (`UIDeviceOrientation.landscapeLeft`).
    case topLeft
    case topRight

    /// From the accelerometer (gravity in the phone's own axes: upright is
    /// y = −1). Flat on a table keeps the last reading; the margin stops a 45°
    /// hold flickering between two.
    static func reading(x: Double, y: Double, z: Double, was: CameraTilt) -> CameraTilt {
        guard abs(z) < 0.8 else { return was }
        if abs(x) > abs(y) + 0.25 { return x < 0 ? .topLeft : .topRight }
        if abs(y) > abs(x) + 0.25 { return y < 0 ? .upright : .upsideDown }
        return was
    }

    var isLandscape: Bool { self == .topLeft || self == .topRight }

    /// `AVCaptureConnection.videoRotationAngle` for a level shot: the back
    /// sensor's native frame is the phone held top-left. The front sensor is
    /// mounted mirrored, so its two sideways angles swap (upright is the same).
    func captureAngle(frontCamera: Bool) -> CGFloat {
        switch self {
        case .upright: 90
        case .upsideDown: 270
        case .topLeft: frontCamera ? 180 : 0
        case .topRight: frontCamera ? 0 : 180
        }
    }
}

/// Where the other camera's inset sits in a two-camera shot. Always inside the
/// centred square: `MomentStore` crops thumbnails to it, so the widget, the
/// library tile and the banner show the inset too.
enum DualShotLayout {
    /// Clockwise, so a quarter turn of the phone is a step through them.
    enum Corner: Int, CaseIterable, Codable, Sendable {
        case topLeading, topTrailing, bottomTrailing, bottomLeading

        var next: Corner { Corner(rawValue: (rawValue + 1) % 4) ?? .topLeading }

        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }

        /// The photo's corner under this corner of the portrait screen, the
        /// phone held `tilt`: the photo is shot level, the screen doesn't turn.
        func inPhoto(tilt: CameraTilt) -> Corner {
            let steps = switch tilt {
            case .upright: 0
            case .topLeft: 3
            case .upsideDown: 2
            case .topRight: 1
            }
            return Corner(rawValue: (rawValue + steps) % 4) ?? self
        }

        /// Where a dragged inset settles: the corner of the quadrant its centre is in.
        static func nearest(to point: CGPoint, in size: CGSize) -> Corner {
            switch (point.y < size.height / 2, point.x < size.width / 2) {
            case (true, true): .topLeading
            case (true, false): .topTrailing
            case (false, false): .bottomTrailing
            case (false, true): .bottomLeading
            }
        }
    }

    /// Where the inset sits along each axis of the square, 0 at the leading
    /// (top) margin, 1 at the trailing (bottom) one. The live preview snaps to
    /// corners; once the shot is in, the composer lets it sit anywhere.
    struct Placement: Equatable, Sendable {
        var x: CGFloat
        var y: CGFloat

        init(x: CGFloat, y: CGFloat) {
            self.x = min(max(x, 0), 1)
            self.y = min(max(y, 0), 1)
        }

        init(_ corner: Corner) {
            self.init(x: corner.isLeading ? 0 : 1, y: corner.isTop ? 0 : 1)
        }

        /// The corner it's nearest, for stepping round them by assistive action.
        var corner: Corner {
            switch (y < 0.5, x < 0.5) {
            case (true, true): .topLeading
            case (true, false): .topTrailing
            case (false, false): .bottomTrailing
            case (false, true): .bottomLeading
            }
        }
    }

    /// The inset's short side, as a share of the main picture's.
    static let insetShare: CGFloat = 0.3

    static func insetRect(main: CGSize, inset: CGSize, corner: Corner) -> CGRect {
        insetRect(main: main, inset: inset, placement: Placement(corner))
    }

    /// `inset` gives only the shape: its short side becomes `insetShare` of
    /// the main picture's, kept a margin inside the centred square.
    static func insetRect(main: CGSize, inset: CGSize, placement: Placement) -> CGRect {
        let (square, margin, size) = frame(main: main, inset: inset)
        return CGRect(x: square.minX + margin + placement.x * (square.width - 2 * margin - size.width),
                      y: square.minY + margin + placement.y * (square.height - 2 * margin - size.height),
                      width: size.width, height: size.height)
    }

    /// A drag of `translation` (in `main`'s units) from `placement`, held inside the square.
    static func moved(_ placement: Placement, by translation: CGSize, main: CGSize, inset: CGSize) -> Placement {
        let (square, margin, size) = frame(main: main, inset: inset)
        let travel = CGSize(width: square.width - 2 * margin - size.width,
                            height: square.height - 2 * margin - size.height)
        return Placement(x: placement.x + translation.width / max(travel.width, 1),
                         y: placement.y + translation.height / max(travel.height, 1))
    }

    private static func frame(main: CGSize, inset: CGSize) -> (square: CGRect, margin: CGFloat, size: CGSize) {
        let side = min(main.width, main.height)
        let short = side * insetShare
        let size = inset.width <= inset.height
            ? CGSize(width: short, height: short * inset.height / max(inset.width, 1))
            : CGSize(width: short * inset.width / max(inset.height, 1), height: short)
        let square = CGRect(x: (main.width - side) / 2, y: (main.height - side) / 2, width: side, height: side)
        return (square, side * 0.04, size)
    }

    static func cornerRadius(inset: CGSize) -> CGFloat { min(inset.width, inset.height) * 0.1 }

    /// A hairline frame: about 6 px on a 1536 px-wide shot.
    static func borderWidth(main: CGSize) -> CGFloat { max(1, min(main.width, main.height) * 0.004) }
}

/// Whether the scene is dark enough that "best quality" capture gathers
/// frames for a while after the press, so the phone must be held still.
enum CameraLowLight {
    /// Dark once auto-exposure has run out of shutter (its longest allowed
    /// exposure) and pushed gain a third of the way up; light again only
    /// below a fifth, so a scene on the edge doesn't flicker.
    static func isDark(exposure: Double, maxExposure: Double,
                       iso: Double, minISO: Double, maxISO: Double,
                       was: Bool) -> Bool {
        guard maxExposure > 0, maxISO > minISO else { return false }
        let gain = (iso - minISO) / (maxISO - minISO)
        let shutterSpent = exposure >= maxExposure * (was ? 0.7 : 0.9)
        return shutterSpent && gain >= (was ? 0.2 : 1.0 / 3)
    }
}

enum CameraFlash: String, CaseIterable, Codable, Sendable {
    case auto, on, off

    /// The remembered choice where this camera has it, else auto, else off —
    /// so a front camera without flash doesn't overwrite the back's "on".
    func resolved(in supported: [CameraFlash]) -> CameraFlash {
        if supported.contains(self) { return self }
        return supported.contains(.auto) ? .auto : .off
    }

    /// Cycles through only what the current camera supports.
    func next(in supported: [CameraFlash]) -> CameraFlash {
        let order = Self.allCases.filter(supported.contains)
        guard let index = order.firstIndex(of: self) else { return order.first ?? .off }
        return order[(index + 1) % order.count]
    }
}

enum CameraTimer: Int, CaseIterable, Codable, Sendable {
    case off = 0, three = 3, ten = 10

    var next: CameraTimer {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    /// Position in the Camera Control's picker, which lists `allCases`.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    init(index: Int) {
        self = Self.allCases.indices.contains(index) ? Self.allCases[index] : .off
    }
}

/// The camera's last choices, per device (`SharedStore.cameraSettings`).
struct CameraSettings: Codable, Equatable, Sendable {
    var frontCamera = true
    var flash: CameraFlash = .auto
    var timer: CameraTimer = .off

    init(frontCamera: Bool = true, flash: CameraFlash = .auto, timer: CameraTimer = .off) {
        self.frontCamera = frontCamera
        self.flash = flash
        self.timer = timer
    }

    /// Field by field: a value another build wrote that this one can't read
    /// costs that field, not the other two.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frontCamera = (try? container.decodeIfPresent(Bool.self, forKey: .frontCamera)) ?? true
        flash = (try? container.decodeIfPresent(CameraFlash.self, forKey: .flash)) ?? .auto
        timer = (try? container.decodeIfPresent(CameraTimer.self, forKey: .timer)) ?? .off
    }
}
