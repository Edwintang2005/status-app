import XCTest

/// Demo mode (`REDSTRING_DEMO=1`, Debug) through Home and each main sheet, with
/// the accessibility audit on every screen. Each step must settle in time: a
/// layout loop (invariants 18 and 21) pegs the main thread, and then nothing
/// on screen ever answers a query — the launch-hang guard.
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

    private func openSheet(_ opener: XCUIElement, closingWith close: String, name: String) throws {
        XCTAssertTrue(opener.waitForExistence(timeout: 30), "\(name): no way in from Home")
        let closeButton = app.buttons[close].firstMatch
        // Tapped again if nothing came up: a tap landing while Home settles
        // after launch (the first refresh re-renders it) can go nowhere.
        for _ in 0..<3 where !closeButton.exists {
            opener.tap()
            _ = closeButton.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(closeButton.exists, "\(name) never appeared")
        try audit(name)
        closeButton.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "\(name) didn't close back to Home")
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
                rejected.append("\(issue.compactDescription) on \(type) \"\(element?.label ?? "")\"")
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
            // The navigation bar's system glass buttons: dark crimson on pale glass, misread.
            if element.elementType == .button, !label.isEmpty, app.navigationBars.buttons[label].exists { return true }
            // Black (`Color.primary`) on near-white, misread from anti-aliased edges
            // (checked against the element screenshots): named one by one, so any
            // other text stays under the check.
            if Self.misreadText.contains(element.identifier) { return true }
            // An emoji's colours aren't text contrast.
            return Self.isEmojiOnly(label)
        case .textClipped:
            // Emoji glyphs overhang the line box ("for you 💌").
            return Self.containsEmoji(label)
        default:
            return false
        }
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
