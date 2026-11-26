import XCTest

/// Drawing on a photo keeps the whole photo, in its own shape.
final class DrawingExportTests: XCTestCase {
    func testAPhotoIsExportedInItsOwnShape() {
        let portrait = DrawingController.aspect(of: CGSize(width: 1536, height: 2048))
        XCTAssertEqual(DrawingController.exportSize(aspect: portrait, longSide: 2048), CGSize(width: 1536, height: 2048))
        let landscape = DrawingController.aspect(of: CGSize(width: 2048, height: 1152))
        XCTAssertEqual(DrawingController.exportSize(aspect: landscape, longSide: 2048), CGSize(width: 2048, height: 1152))
        XCTAssertEqual(DrawingController.exportSize(aspect: 1, longSide: 2048), CGSize(width: 2048, height: 2048),
                       "a doodle stays square")
    }

    func testTheStrokesAreReadFromThatShape() {
        let canvas = CGRect(x: 0, y: 0, width: 335, height: 447)
        let rect = DrawingController.centred(aspect: 3.0 / 4.0, in: canvas)
        XCTAssertEqual(rect.width, 335, accuracy: 0.01)
        XCTAssertEqual(rect.height, 446.67, accuracy: 0.01, "layout's rounding is trimmed, not stretched")
        XCTAssertEqual(rect.midY, canvas.midY, accuracy: 0.01)
        XCTAssertEqual(DrawingController.centred(aspect: 1, in: CGRect(x: 0, y: 0, width: 300, height: 400)),
                       CGRect(x: 0, y: 50, width: 300, height: 300))
    }

    func testADegenerateSizeCountsAsSquare() {
        XCTAssertEqual(DrawingController.aspect(of: .zero), 1)
    }
}
