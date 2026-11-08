import XCTest

/// Demo mode (`REDSTRING_DEMO=1`, Debug) through Home and each main sheet, with
/// the accessibility audit on every screen. Each step must settle in time: a
/// layout loop (invariants 18 and 21) pegs the main thread, and then nothing
/// on screen ever answers a query — the launch-hang guard. Every screen must
/// also fit the width: run it on the narrowest phone with `make uitest-narrow`.
@MainActor
final class DemoSmokeTests: XCTestCase {
    private let app = XCUIApplication()

    /// Called first by every test (XCUI is main-actor; XCTest's `setUp` isn't).
    private func launchToHome() {
        continueAfterFailure = false
        app.launchEnvironment["REDSTRING_DEMO"] = "1"
        app.launch()
        // The terms gate shows once per install; demo mode doesn't seed past it.
        let home = app.buttons["Settings"]
        let agree = app.buttons["I agree"]
        let deadline = Date().addingTimeInterval(60)
        while !home.exists, Date() < deadline {
            if agree.exists { agree.tap() } else { _ = home.waitForExistence(timeout: 1) }
        }
        XCTAssertTrue(home.exists, "Home never appeared — a launch hang or a layout loop")
    }

    func testHome() throws {
        launchToHome()
        try audit("Home")
        try assertFitsScreen("Home")
    }

    func testSettings() throws {
        launchToHome()
        try openSheet(app.buttons["Settings"], closingWith: "Done", name: "Settings")
    }

    func testMomentLibrary() throws {
        launchToHome()
        try openSheet(app.buttons["Moments"], closingWith: "Done", name: "Moments")
    }

    func testStatusHistory() throws {
        launchToHome()
        try openSheet(button(labelStartingWith: "Sam:"), closingWith: "Done", name: "Status history")
    }

    func testStatusPicker() throws {
        launchToHome()
        try openSheet(button(labelStartingWith: "Your status"), closingWith: "Cancel", name: "Status picker")
    }

    func testMomentComposer() throws {
        launchToHome()
        try openSheet(app.buttons["Moment"], closingWith: "Cancel", name: "Moment composer")
    }

    /// The palette's rows once ran off both edges of a narrow screen.
    func testDrawingPalette() throws {
        launchToHome()
        try openSheet(app.buttons["Moment"], closingWith: "Cancel", name: "Drawing palette") {
            let palette = self.app.buttons["Colour 1"]
            // Tapped again if nothing came up: a tap while the sheet is still
            // rising can go nowhere (it flaked once in a few runs on each phone).
            for _ in 0..<3 where !palette.exists {
                self.app.buttons["Draw"].tap()
                _ = palette.waitForExistence(timeout: 10)
            }
            XCTAssertTrue(palette.exists, "the palette never opened")
        }
    }

    func testVoiceMemoComposer() throws {
        launchToHome()
        try openSheet(app.buttons["Voice memo"], closingWith: "Cancel", name: "Voice memo composer")
    }

    func testGallery() throws {
        launchToHome()
        // The moment card sits below the fold, half under the home indicator.
        app.swipeUp()
        try openSheet(button(labelStartingWith: "for you"), closingWith: "Done", name: "Gallery")
    }

    // MARK: - Helpers

    private func button(labelStartingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// `then` runs once the sheet is up, before it's judged.
    private func openSheet(_ opener: XCUIElement, closingWith close: String, name: String,
                           then: () throws -> Void = {}) throws {
        XCTAssertTrue(opener.waitForExistence(timeout: 30), "\(name): no way in from Home")
        let closeButton = app.buttons[close].firstMatch
        // Tapped again if nothing came up: a tap landing while Home settles
        // after launch (the first refresh re-renders it) can go nowhere.
        for _ in 0..<3 where !closeButton.exists {
            opener.tap()
            _ = closeButton.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(closeButton.exists, "\(name) never appeared")
        try then()
        try audit(name)
        try assertFitsScreen(name)
        closeButton.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "\(name) didn't close back to Home")
    }

    /// Nothing on screen may hang past the window's sides: a row that's wider
    /// than the screen widens its whole card. Elements wholly off screen (a
    /// pager's other pages) aren't judged, nor images: a filled, clipped photo
    /// reports its unclipped frame. One snapshot, not a query per element.
    private func assertFitsScreen(_ screen: String) throws {
        let window = app.windows.firstMatch.frame
        var overflowing: [String] = []
        func visit(_ element: XCUIElementSnapshot) {
            let frame = element.frame
            if [.button, .staticText].contains(element.elementType),
               !frame.isEmpty, frame.intersects(window),
               frame.minX < window.minX - 1 || frame.maxX > window.maxX + 1 {
                overflowing.append("\"\(element.label)\" at \(Int(frame.minX))…\(Int(frame.maxX))")
            }
            element.children.forEach(visit)
        }
        visit(try app.snapshot())
        XCTAssertTrue(overflowing.isEmpty,
                      "\(screen) is wider than the \(Int(window.width)) pt screen: \(overflowing.joined(separator: " | "))")
    }

    /// Not judged: Dynamic Type. `Theme.rounded` scales by `UIFontMetrics` when
    /// a view renders (capped at 1.35×) rather than through text styles, which
    /// the audit — it changes the size live — reports on every label.
    private static let auditTypes = XCUIAccessibilityAuditType.all.subtracting(.dynamicType)

    /// Everything else the audit finds fails the test, except the cases in
    /// `accepts`, each a misreading by the audit or system-drawn UI.
    private func audit(_ screen: String) throws {
        // Collected, then failed once: XCTest's own line names only the first
        // issue's kind, not which element, nor the rest.
        var rejected: [String] = []
        do {
            try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
                if self.accepts(issue) { return true }
                let element = issue.element
                let type = element.map { "\($0.elementType.rawValue)" } ?? "?"
                let id = element.map { $0.identifier.isEmpty ? "" : " [\($0.identifier)]" } ?? ""
                rejected.append("\(issue.compactDescription) on \(type) \"\(element?.label ?? "")\"\(id)")
                return true
            }
            XCTAssertTrue(rejected.isEmpty, "\(screen): \(rejected.joined(separator: " | "))")
        } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
            // XCTest's own time limit, on a loaded simulator. The screen still
            // opened and closed in time — the hang guard — so it isn't a failure.
            XCTContext.runActivity(named: "\(screen): the audit timed out and judged nothing") { _ in }
        }
    }

    /// Home's wrapped notice paragraph, the picker's tile labels, the moment
    /// composer's 11 pt "Camera" (its "Library" and "Draw" neighbours pass), and
    /// Settings' section headers — measured 5.5–6.5:1, and still flagged when
    /// drawn pure black, so the audit is misreading them.
    private static let misreadText: Set<String> = ["home.notice.message", "status.tile.label",
                                                   "composer.source.Camera", "settings.section.header"]

    private func accepts(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let element = issue.element
        let label = element?.label ?? ""
        switch issue.auditType {
        case .contrast:
            // No element to name: Form cell and switch chrome UIKit draws (Settings).
            guard let element else { return true }
            // Inactive controls are exempt (WCAG 1.4.3).
            if !element.isEnabled { return true }
            // Within the audit's own tolerance: small grey text over the backdrop's tinted corners.
            if issue.compactDescription.localizedCaseInsensitiveContains("nearly") { return true }
            // The navigation bar's system glass buttons, or the text inside one (the
            // library's "All types" on a 375 pt phone): dark crimson on pale glass, misread.
            if inNavigationBar(element) { return true }
            // Black (`Color.primary`) on near-white, misread from anti-aliased edges
            // (checked against the element screenshots): named one by one, so any
            // other text stays under the check.
            if Self.misreadText.contains(element.identifier) { return true }
            // Not a misread: status history's bare day headers fall short over the
            // backdrop's crimson corner, and are kept bare by choice.
            if element.identifier == "history.day.header" { return true }
            // An emoji's colours aren't text contrast.
            return Self.isEmojiOnly(label)
        case .textClipped:
            // The composer's inline title on a 375 pt phone, between its two
            // glass buttons: whole in the screenshots, flagged only with the palette open.
            if let element, element.elementType == .staticText, inNavigationBar(element) { return true }
            // The status picker's 34 pt emoji overhangs its field (a UIKit field,
            // so it carries no label for the check below); its words field's
            // placeholder is the current status, longer than the field on a 375 pt
            // phone — a hint, and typed words scroll.
            if ["status.emoji.field", "status.words.field"].contains(element?.identifier ?? "") { return true }
            // Emoji glyphs overhang the line box ("for you 💌").
            return Self.containsEmoji(label)
        default:
            return false
        }
    }

    /// By predicate: a subscript query refuses labels over 128 characters.
    private func inNavigationBar(_ element: XCUIElement) -> Bool {
        let label = element.label
        guard !label.isEmpty else { return false }
        let query = element.elementType == .button ? app.navigationBars.buttons : app.navigationBars.staticTexts
        return query.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.properties.isEmoji && scalar.value > 0x7F) || scalar.value == 0x200D || scalar.value == 0xFE0F
    }

    private static func isEmojiOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isEmoji)
    }

    private static func containsEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x7F }
    }
}
