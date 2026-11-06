import CoreGraphics
import XCTest

/// A sheet that opened as toolbar and backdrop only: when it counts as blank,
/// and how its measurements are kept for Diagnostics.
final class LayoutGlitchTests: XCTestCase {
    private let sheet = CGSize(width: 402, height: 780)

    func testBlankMeansNothingToShowInView() {
        XCTAssertTrue(LayoutGlitch.isBlank(nil, visible: sheet), "never laid out")
        XCTAssertTrue(LayoutGlitch.isBlank(CGRect(x: 0, y: 0, width: 0, height: 1_400), visible: sheet), "no width")
        XCTAssertTrue(LayoutGlitch.isBlank(CGRect(x: 0, y: 2_000, width: 402, height: 1_400), visible: sheet),
                      "laid out below everything the sheet shows")
        XCTAssertFalse(LayoutGlitch.isBlank(CGRect(x: 0, y: 0, width: 402, height: 1_400), visible: sheet))
        XCTAssertFalse(LayoutGlitch.isBlank(CGRect(x: 0, y: -600, width: 402, height: 1_400), visible: sheet),
                       "scrolled, still on screen")
        XCTAssertFalse(LayoutGlitch.isBlank(CGRect(x: 0, y: 0, width: 402, height: 900), visible: nil),
                       "a sized body with no known space is given the benefit of the doubt")
    }

    func testTheRebuildsOutcomeReplacesItsOwnEntry() {
        var glitch = LayoutGlitch(at: Date(timeIntervalSince1970: 100), sheet: "Status picker",
                                  container: "402×780", insets: "0,0,34,0", content: "never laid out")
        var list = LayoutGlitch.recording(glitch, in: [], limit: 3)
        glitch.healed = true
        list = LayoutGlitch.recording(glitch, in: list, limit: 3)
        XCTAssertEqual(list, [glitch], "one entry, now with its outcome")
        XCTAssertTrue(list[0].summary.contains("rebuilt, fixed"))

        let later = (1...4).map {
            LayoutGlitch(at: Date(timeIntervalSince1970: TimeInterval(100 + $0)), sheet: "Status picker",
                         container: "", insets: "", content: "")
        }
        list = later.reduce(list) { LayoutGlitch.recording($1, in: $0, limit: 3) }
        XCTAssertEqual(list.map(\.at.timeIntervalSince1970), [104, 103, 102], "newest first, capped")
    }

    func testGlitchesRoundTripTheStore() {
        let store = SharedStore(defaults: temporaryDefaults())
        let glitch = LayoutGlitch(at: Date(timeIntervalSince1970: 100), sheet: "Status picker",
                                  container: "402×780", insets: "0,0,34,0", content: "0×1400 at 0,0", healed: false)
        store.layoutGlitches = [glitch]
        XCTAssertEqual(store.layoutGlitches, [glitch])
    }
}
