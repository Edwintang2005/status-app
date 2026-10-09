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
        XCTAssertEqual(triple.activePreset(for: 3.99), 4, "a ramp landing a hair short still counts")
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
}
