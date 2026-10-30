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
        XCTAssertEqual(CameraTilt.reading(x: 0, y: -1, z: 0, was: .topLeft), .upright)
        XCTAssertEqual(CameraTilt.reading(x: 0, y: 1, z: 0, was: .upright), .upsideDown)
        XCTAssertEqual(CameraTilt.reading(x: -1, y: 0, z: 0, was: .upright), .topLeft)
        XCTAssertEqual(CameraTilt.reading(x: 0.95, y: 0.1, z: 0.2, was: .upright), .topRight)
        XCTAssertEqual(CameraTilt.reading(x: 0.6, y: -0.55, z: 0.3, was: .topRight), .topRight, "near 45° keeps the last")
        XCTAssertEqual(CameraTilt.reading(x: 0.6, y: -0.55, z: 0.3, was: .upright), .upright)
        XCTAssertEqual(CameraTilt.reading(x: 0, y: -0.1, z: -0.99, was: .topLeft), .topLeft, "flat keeps the last")
    }

    func testTiltGivesTheLevelCaptureAngle() {
        for front in [false, true] {
            XCTAssertEqual(CameraTilt.upright.captureAngle(frontCamera: front), 90)
            XCTAssertEqual(CameraTilt.upsideDown.captureAngle(frontCamera: front), 270)
        }
        XCTAssertEqual(CameraTilt.topLeft.captureAngle(frontCamera: false), 0, "the back sensor's native frame")
        XCTAssertEqual(CameraTilt.topRight.captureAngle(frontCamera: false), 180)
        XCTAssertEqual(CameraTilt.topLeft.captureAngle(frontCamera: true), 180, "the front sensor is mounted mirrored")
        XCTAssertEqual(CameraTilt.topRight.captureAngle(frontCamera: true), 0)
        XCTAssertTrue(CameraTilt.topRight.isLandscape)
        XCTAssertFalse(CameraTilt.upsideDown.isLandscape)
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

    // MARK: Both cameras

    /// Thumbnails crop to the centred square: the inset must be wholly inside it, every corner, either way up.
    func testInsetSitsInsideTheThumbnailSquare() {
        for main in [CGSize(width: 1536, height: 2048), CGSize(width: 2048, height: 1536)] {
            let side = min(main.width, main.height)
            let square = CGRect(x: (main.width - side) / 2, y: (main.height - side) / 2, width: side, height: side)
            for corner in DualShotLayout.Corner.allCases {
                let shape = CGSize(width: main.width, height: main.height)
                let rect = DualShotLayout.insetRect(main: main, inset: shape, corner: corner)
                XCTAssertTrue(square.contains(rect), "\(corner) in \(main)")
                XCTAssertEqual(min(rect.width, rect.height), side * DualShotLayout.insetShare, accuracy: 0.5)
                XCTAssertEqual(rect.width / rect.height, main.width / main.height, accuracy: 0.01, "keeps its shape")
                XCTAssertEqual(rect.midX < main.width / 2, corner.isLeading)
                XCTAssertEqual(rect.midY < main.height / 2, corner.isTop)
            }
        }
    }

    /// The screen doesn't turn but the photo is shot level: the inset lands in
    /// the photo's corner that sat under the chosen one on screen.
    func testInsetCornerFollowsTheTurnedPhone() {
        let corner = DualShotLayout.Corner.topLeading
        XCTAssertEqual(corner.inPhoto(tilt: .upright), .topLeading)
        XCTAssertEqual(corner.inPhoto(tilt: .topLeft), .bottomLeading, "top of the phone to the left")
        XCTAssertEqual(corner.inPhoto(tilt: .topRight), .topTrailing)
        XCTAssertEqual(corner.inPhoto(tilt: .upsideDown), .bottomTrailing)
        XCTAssertEqual(DualShotLayout.Corner.topTrailing.inPhoto(tilt: .topLeft), .topLeading)
        XCTAssertEqual(DualShotLayout.Corner.bottomLeading.next, .topLeading)
    }

    /// After the shot the inset moves freely, but never out of the thumbnail's square.
    func testMovedInsetStaysInsideTheSquare() {
        let main = CGSize(width: 1536, height: 2048)
        let shape = CGSize(width: 3, height: 4)
        let square = CGRect(x: 0, y: 256, width: 1536, height: 1536)
        let start = DualShotLayout.Placement(.topLeading)
        let far = DualShotLayout.moved(start, by: CGSize(width: 5_000, height: -5_000), main: main, inset: shape)
        XCTAssertEqual(far, DualShotLayout.Placement(.topTrailing), "dragged past the edge, it stops at the margin")
        let middle = DualShotLayout.moved(start, by: CGSize(width: 300, height: 300), main: main, inset: shape)
        XCTAssertTrue(middle.x > 0 && middle.x < 1 && middle.y > 0 && middle.y < 1)
        let moved = DualShotLayout.insetRect(main: main, inset: shape, placement: middle)
        let from = DualShotLayout.insetRect(main: main, inset: shape, corner: .topLeading)
        XCTAssertEqual(moved.minX - from.minX, 300, accuracy: 0.5, "follows the finger one to one")
        XCTAssertEqual(moved.minY - from.minY, 300, accuracy: 0.5)
        XCTAssertTrue(square.contains(moved))
        XCTAssertEqual(DualShotLayout.Placement(x: 0.7, y: 0.2).corner, .topTrailing)
    }

    func testBorderIsAHairline() {
        XCTAssertEqual(DualShotLayout.borderWidth(main: CGSize(width: 1536, height: 2048)), 6.144, accuracy: 0.01)
        XCTAssertEqual(DualShotLayout.borderWidth(main: CGSize(width: 90, height: 120)), 1, "never thinner than a pixel")
    }

    func testDraggedInsetSettlesInItsQuadrant() {
        let size = CGSize(width: 300, height: 400)
        XCTAssertEqual(DualShotLayout.Corner.nearest(to: CGPoint(x: 10, y: 10), in: size), .topLeading)
        XCTAssertEqual(DualShotLayout.Corner.nearest(to: CGPoint(x: 290, y: 150), in: size), .topTrailing)
        XCTAssertEqual(DualShotLayout.Corner.nearest(to: CGPoint(x: 160, y: 390), in: size), .bottomTrailing)
        XCTAssertEqual(DualShotLayout.Corner.nearest(to: CGPoint(x: 20, y: 300), in: size), .bottomLeading)
    }
}
