import XCTest

/// Drawing on a photo keeps the whole photo, the strokes where they were drawn.
final class DrawingExportTests: XCTestCase {
    func testAPhotoIsExportedInItsOwnShape() {
        let portrait = DrawingController.aspect(of: CGSize(width: 1536, height: 2048))
        XCTAssertEqual(DrawingController.exportSize(aspect: portrait, longSide: 2048), CGSize(width: 1536, height: 2048))
        let landscape = DrawingController.aspect(of: CGSize(width: 2048, height: 1152))
        XCTAssertEqual(DrawingController.exportSize(aspect: landscape, longSide: 2048), CGSize(width: 2048, height: 1152))
        XCTAssertEqual(DrawingController.exportSize(aspect: 1, longSide: 2048), CGSize(width: 2048, height: 2048),
                       "a doodle stays square")
    }

    /// The composer shows a photo's centred square: the strokes land there, the sides are kept.
    func testTheStrokesLandOnThePhotosCentreSquare() {
        let photo = CGRect(origin: .zero, size: CGSize(width: 1365, height: 2048))
        XCTAssertEqual(DrawingController.centred(aspect: 1, in: photo), CGRect(x: 0, y: 341.5, width: 1365, height: 1365))
        let wide = CGRect(origin: .zero, size: CGSize(width: 2048, height: 1152))
        XCTAssertEqual(DrawingController.centred(aspect: 1, in: wide), CGRect(x: 448, y: 0, width: 1152, height: 1152))
    }

    func testADegenerateSizeCountsAsSquare() {
        XCTAssertEqual(DrawingController.aspect(of: .zero), 1)
    }
}
