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
