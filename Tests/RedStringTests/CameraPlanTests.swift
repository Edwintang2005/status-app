import XCTest

final class CameraPlanTests: XCTestCase {
    /// iPhone 15 Pro Max-style triple camera: ultra wide at 1, wide at 2, 5× tele at 10.
    private let triple = CameraLensPlan(switchOverFactors: [2, 10], hasUltraWide: true,
                                        minAvailable: 1, maxAvailable: 123.75,
                                        offersTwoTimes: true)

    func testTripleCameraShowsUltraWideWideCropAndTele() {
        XCTAssertEqual(triple.displayMultiplier, 0.5)
        XCTAssertEqual(triple.presets.map(triple.displayed), [0.5, 1, 2, 5])
        XCTAssertEqual(triple.defaultZoom, 2, "opens on the wide lens, shown as 1×")
        XCTAssertEqual(triple.displayed(triple.maxZoom), CameraLensPlan.maxDisplayZoom)
    }

    func testSystemMultiplierWins() {
        let plan = CameraLensPlan(switchOverFactors: [2, 6], hasUltraWide: true,
                                  minAvailable: 1, maxAvailable: 100,
                                  systemMultiplier: 0.5, offersTwoTimes: true)
        XCTAssertEqual(plan.presets.map(plan.displayed), [0.5, 1, 2, 3])
    }

    func testDualTelephotoDoesNotDuplicateTwoTimes() {
        let plan = CameraLensPlan(switchOverFactors: [2], hasUltraWide: false,
                                  minAvailable: 1, maxAvailable: 16, offersTwoTimes: true)
        XCTAssertEqual(plan.presets, [1, 2])
        XCTAssertEqual(plan.defaultZoom, 1)
    }

    func testSingleWideGetsDigitalTwoTimes() {
        let plan = CameraLensPlan(switchOverFactors: [], hasUltraWide: false,
                                  minAvailable: 1, maxAvailable: 16, offersTwoTimes: true)
        XCTAssertEqual(plan.presets, [1, 2])
    }

    func testFrontCameraHasNoLensRow() {
        let plan = CameraLensPlan(switchOverFactors: [], hasUltraWide: false,
                                  minAvailable: 1, maxAvailable: 16, offersTwoTimes: false)
        XCTAssertEqual(plan.presets, [1])
    }

    func testTwoTimesSkippedPastTheMaximum() {
        let plan = CameraLensPlan(switchOverFactors: [], hasUltraWide: false,
                                  minAvailable: 1, maxAvailable: 1.5, offersTwoTimes: true)
        XCTAssertEqual(plan.presets, [1])
        XCTAssertEqual(plan.clamped(4), 1.5)
        XCTAssertEqual(plan.clamped(0.2), 1)
    }

    func testActivePresetIsTheWidestLensAtOrBelowTheZoom() {
        XCTAssertEqual(triple.activePreset(for: 1), 1)
        XCTAssertEqual(triple.activePreset(for: 2.8), 2, "1.4× lights the 1× button")
        XCTAssertEqual(triple.activePreset(for: 3.99), 4, "a zoom a hair short of a lens still counts")
        XCTAssertEqual(triple.activePreset(for: 30), 10)
    }

    func testLabels() {
        XCTAssertEqual(CameraLensPlan.label(0.5), "0.5×")
        XCTAssertEqual(CameraLensPlan.label(1), "1×")
        XCTAssertEqual(CameraLensPlan.label(2.04), "2×")
    }

    func testFlashCyclesThroughSupportedModesOnly() {
        XCTAssertEqual(CameraFlash.auto.next(in: [.auto, .on, .off]), .on)
        XCTAssertEqual(CameraFlash.off.next(in: [.auto, .on, .off]), .auto)
        XCTAssertEqual(CameraFlash.auto.next(in: [.off, .on]), .on, "an unsupported mode falls to the first, in auto-on-off order")
        XCTAssertEqual(CameraFlash.on.next(in: []), .off)
    }

    func testTimerCyclesAndMapsPickerIndexes() {
        XCTAssertEqual(CameraTimer.off.next, .three)
        XCTAssertEqual(CameraTimer.ten.next, .off)
        XCTAssertEqual(CameraTimer(index: CameraTimer.ten.index), .ten)
        XCTAssertEqual(CameraTimer(index: 7), .off)
    }

    func testFlashFallsBackWithoutLosingTheChoice() {
        XCTAssertEqual(CameraFlash.on.resolved(in: [.auto, .on, .off]), .on)
        XCTAssertEqual(CameraFlash.on.resolved(in: [.auto, .off]), .auto)
        XCTAssertEqual(CameraFlash.on.resolved(in: []), .off, "a camera with no flash")
    }

    func testSettingsRoundTripThroughTheStore() {
        let store = SharedStore(defaults: temporaryDefaults())
        XCTAssertEqual(store.cameraSettings, CameraSettings(), "front, auto, no timer by default")
        let chosen = CameraSettings(frontCamera: false, flash: .on, timer: .ten)
        store.cameraSettings = chosen
        XCTAssertEqual(store.cameraSettings, chosen)
        store.clearPairing(keepingName: false)
        XCTAssertEqual(store.cameraSettings, chosen, "a device preference, not pairing state")
    }

    func testSettingsDecodeFieldByField() throws {
        let newer = try decode(CameraSettings.self, #"{"frontCamera":false,"flash":"torch","timer":10}"#)
        XCTAssertEqual(newer, CameraSettings(frontCamera: false, flash: .auto, timer: .ten),
                       "an unknown flash mode costs only the flash")
        XCTAssertEqual(try decode(CameraSettings.self, "{}"), CameraSettings())
        XCTAssertEqual(try decode(CameraSettings.self, #"{"timer":5}"#).timer, .off)
    }

    /// iPhone 14 Pro-style front camera: one 12 MP sensor, digital zoom only.
    private let selfie = CameraLensPlan(switchOverFactors: [], hasUltraWide: false,
                                        minAvailable: 1, maxAvailable: 16,
                                        offersTwoTimes: false, isSelfie: true)

    func testSelfieOpensCroppedUprightAndWideSideways() {
        XCTAssertEqual(selfie.presets, [1], "no lens pills on the front")
        XCTAssertEqual(selfie.openingZoom(landscape: false), CameraLensPlan.selfieCrop)
        XCTAssertEqual(selfie.openingZoom(landscape: true), 1, "sideways shows the whole sensor")
        XCTAssertFalse(selfie.isSelfieWide(CameraLensPlan.selfieCrop))
        XCTAssertTrue(selfie.isSelfieWide(1))
    }

    func testSelfieButtonTogglesBetweenTheTwoFramings() {
        XCTAssertEqual(selfie.selfieToggled(from: CameraLensPlan.selfieCrop), 1)
        XCTAssertEqual(selfie.selfieToggled(from: 1), CameraLensPlan.selfieCrop)
        XCTAssertEqual(selfie.selfieToggled(from: 1.1), CameraLensPlan.selfieCrop, "a pinch near wide counts as wide")
        XCTAssertEqual(selfie.selfieToggled(from: 3), 1, "zoomed in past the crop expands to wide")
    }

    func testBackCameraIgnoresOrientation() {
        XCTAssertNil(triple.selfieNarrowZoom)
        XCTAssertEqual(triple.openingZoom(landscape: true), triple.defaultZoom)
        XCTAssertFalse(triple.isSelfieWide(1))
        XCTAssertEqual(triple.selfieToggled(from: 2), 2)
    }

    func testSelfieWithoutRoomToCropHasNoButton() {
        let plan = CameraLensPlan(switchOverFactors: [], hasUltraWide: false,
                                  minAvailable: 1, maxAvailable: 1.2,
                                  offersTwoTimes: false, isSelfie: true)
        XCTAssertNil(plan.selfieNarrowZoom)
        XCTAssertEqual(plan.openingZoom(landscape: false), 1)
    }

    func testTiltReadsGravityWithHysteresis() {
        XCTAssertFalse(CameraTilt.isLandscape(x: 0, y: -1, z: 0, was: true), "upright")
        XCTAssertTrue(CameraTilt.isLandscape(x: -1, y: 0, z: 0, was: false), "sideways, either way round")
        XCTAssertTrue(CameraTilt.isLandscape(x: 0.95, y: 0.1, z: 0.2, was: false))
        XCTAssertTrue(CameraTilt.isLandscape(x: 0.6, y: 0.55, z: 0.3, was: true), "near 45° keeps the last")
        XCTAssertFalse(CameraTilt.isLandscape(x: 0.6, y: 0.55, z: 0.3, was: false))
        XCTAssertTrue(CameraTilt.isLandscape(x: 0, y: -0.1, z: -0.99, was: true), "flat keeps the last")
    }

    func testLowLightNeedsShutterAndGainSpent() {
        func dark(_ exposure: Double, _ iso: Double, was: Bool) -> Bool {
            CameraLowLight.isDark(exposure: exposure, maxExposure: 1.0 / 30,
                                  iso: iso, minISO: 50, maxISO: 2050, was: was)
        }
        XCTAssertFalse(dark(1.0 / 120, 1500, was: false), "fast shutter: there's light to spare")
        XCTAssertFalse(dark(1.0 / 30, 400, was: false), "slow shutter, low gain: a dim room, not dark")
        XCTAssertTrue(dark(1.0 / 30, 800, was: false))
        XCTAssertTrue(dark(1.0 / 33, 500, was: true), "stays dark down to a fifth of the gain")
        XCTAssertFalse(dark(1.0 / 33, 400, was: true))
        XCTAssertFalse(CameraLowLight.isDark(exposure: 1, maxExposure: 0, iso: 1, minISO: 1, maxISO: 1, was: true),
                       "a format with no ranges never reads dark")
    }
}
