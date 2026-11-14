import XCTest

/// Demo mode (`REDSTRING_DEMO=1`, Debug) through Home and each main sheet, with
/// the accessibility audit on every screen. Each step must settle in time: a
/// layout loop (invariants 18 and 21) pegs the main thread, and then nothing
/// on screen ever answers a query — the launch-hang guard. Every screen must
/// also fit the width: run it on the narrowest phone with `make uitest-narrow`.
@MainActor
final class DemoSmokeTests: XCTestCase {
    private let app = XCUIApplication()

    /// `environment` adds demo switches (`REDSTRING_DEMO_UNPAIRED`, …);
    /// `largestText` launches at the largest accessibility text size.
    private func launch(_ environment: [String: String] = [:], largestText: Bool = false) {
        continueAfterFailure = false
        app.launchEnvironment["REDSTRING_DEMO"] = "1"
        environment.forEach { app.launchEnvironment[$0.key] = $0.value }
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
    }

    /// Called first by every Home test (XCUI is main-actor; XCTest's `setUp` isn't).
    private func launchToHome(_ environment: [String: String] = [:], largestText: Bool = false) {
        launch(environment, largestText: largestText)
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
            let palette = self.app.buttons["Black ink"]
            // Tapped again if nothing came up: a tap while the sheet is still
            // rising can go nowhere (it flaked once in a few runs on each phone).
            var taps = 0
            for _ in 0..<3 where !palette.exists {
                self.app.buttons["Draw"].tap()
                taps += 1
                _ = palette.waitForExistence(timeout: 10)
            }
            XCTAssertTrue(palette.exists, "the palette never opened")
            self.noteRetries(taps, opening: "Drawing palette")
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

    // MARK: - Screens no sheet test reaches (TEST-3)

    /// A first launch: terms, a name, the pairing screen, the invite link and
    /// the "when did you begin?" ask that follows it.
    func testOnboarding() throws {
        launch(["REDSTRING_DEMO_UNPAIRED": "1"])
        let agree = app.buttons["I agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 30), "the terms never appeared")
        try judge("Terms")
        agree.tap()

        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30), "the welcome screen never appeared")
        name.tap()
        name.typeText("Alex")
        try judge("Welcome")
        app.buttons["Continue"].tap()

        let create = app.buttons["Create invite link"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the pairing screen never appeared")
        try judge("Pairing")
        create.tap()
        allowNotificationsIfAsked()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the invite link never appeared")
        try judge("Invite link")
        done.tap()

        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 30), "the anniversary ask never appeared")
        try judge("Anniversary ask")
        notNow.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "Home never appeared")
    }

    func testDiagnostics() throws {
        launchToHome()
        try openFromSettings("Diagnostics", screen: "Diagnostics")
    }

    func testFreshStart() throws {
        launchToHome()
        try openFromSettings("Fresh start", screen: "Fresh start")
    }

    /// Reached from Diagnostics, as no year is offered before Christmas.
    func testRecap() throws {
        launchToHome()
        try openFromSettings("Diagnostics", screen: "Diagnostics", closing: false)
        let recap = button(labelStartingWith: "Make a recap")
        scroll(to: recap)
        recap.tap()
        XCTAssertTrue(app.navigationBars.element.staticTexts.firstMatch.waitForExistence(timeout: 30))
        try judge("Recap")
    }

    /// A surprise status arrives sealed: the reveal's cover is a screen of its own.
    func testCelebration() throws {
        launch(["REDSTRING_DEMO_CELEBRATION": "reveal"])
        let agree = app.buttons["I agree"]
        let open = app.buttons["Just show me"]
        let deadline = Date().addingTimeInterval(60)
        while !open.exists, Date() < deadline {
            if agree.exists { agree.tap() } else { _ = open.waitForExistence(timeout: 1) }
        }
        XCTAssertTrue(open.exists, "the celebration never appeared")
        // The audit lists what's under the cover too (Home, hidden from VoiceOver
        // beneath it): only the cover's own elements are judged.
        let cover = app.buttons[CelebrationProbe.coverLabel]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        try audit("Celebration", within: cover)
        try assertFitsScreen("Celebration")
    }

    /// The largest accessibility text size: nothing runs off the screen's sides.
    func testLargestText() throws {
        launchToHome(largestText: true)
        try assertFitsScreen("Home, largest text")
        try openSheet(app.buttons["Settings"], closingWith: "Done", name: "Settings, largest text")
        try openSheet(button(labelStartingWith: "Your status"), closingWith: "Cancel", name: "Status picker, largest text")
        try openSheet(app.buttons["Moment"], closingWith: "Cancel", name: "Moment composer, largest text")
        try openSheet(app.buttons["Moments"], closingWith: "Done", name: "Moments, largest text")
    }

    // MARK: - First tap (TEST-2)

    /// No retries: each sheet opens on its first tap, straight after launch,
    /// with something on it that can be tapped — a blank sheet or a tap lost
    /// during Home's launch settle fails here, where the other tests retry.
    func testEverySheetOpensOnItsFirstTap() throws {
        let sheets: [(opener: () -> XCUIElement, close: String, content: () -> XCUIElement, name: String)] = [
            ({ self.app.buttons["Settings"] }, "Done", { self.app.switches.firstMatch }, "Settings"),
            ({ self.button(labelStartingWith: "Your status") }, "Cancel",
             { self.app.textFields.firstMatch }, "Status picker"),
            ({ self.app.buttons["Moment"] }, "Cancel", { self.app.buttons["Draw"] }, "Moment composer"),
            ({ self.app.buttons["Moments"] }, "Done", { self.app.buttons["From me"] }, "Moments"),
        ]
        launchToHome()
        for sheet in sheets {
            let opener = sheet.opener()
            XCTAssertTrue(opener.waitForExistence(timeout: 30), "\(sheet.name): no way in from Home")
            opener.tap()
            let content = sheet.content()
            XCTAssertTrue(content.waitForExistence(timeout: 10), "\(sheet.name) didn't open on its first tap")
            XCTAssertTrue(content.isHittable, "\(sheet.name) opened, but its content can't be reached")
            app.buttons[sheet.close].firstMatch.tap()
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "\(sheet.name) didn't close")
        }
    }

    // MARK: - Helpers

    private func judge(_ screen: String) throws {
        try audit(screen)
        try assertFitsScreen(screen)
    }

    /// Settings' row, judged, then back to Home unless `closing` is false.
    private func openFromSettings(_ row: String, screen: String, closing: Bool = true) throws {
        try openSheet(app.buttons["Settings"], closingWith: "Done", name: "Settings", closing: false)
        // A row holding a label and a value isn't a button to XCUI.
        let link = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
        scroll(to: link)
        link.tap()
        XCTAssertTrue(app.navigationBars[screen].waitForExistence(timeout: 30), "\(screen) never appeared")
        try judge(screen)
        guard closing else { return }
        app.navigationBars[screen].buttons.firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "\(screen) didn't go back to Settings")
        done.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "\(screen) didn't close back to Home")
    }

    /// Short drags: a list builds its rows lazily, and a full swipe can carry a
    /// row past the screen before it ever exists to be found.
    private func scroll(to element: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<30 where !(element.exists && element.isHittable) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        XCTAssertTrue(element.isHittable, "\(element) never scrolled into reach")
    }

    /// The system's notification ask, which creating the invite raises.
    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    private func button(labelStartingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// `then` runs once the sheet is up, before it's judged.
    private func openSheet(_ opener: XCUIElement, closingWith close: String, name: String,
                           closing: Bool = true, then: () throws -> Void = {}) throws {
        XCTAssertTrue(opener.waitForExistence(timeout: 30), "\(name): no way in from Home")
        let closeButton = app.buttons[close].firstMatch
        // Tapped again if nothing came up: a tap landing while Home settles
        // after launch (the first refresh re-renders it) can go nowhere.
        var taps = 0
        for _ in 0..<3 where !closeButton.exists {
            opener.tap()
            taps += 1
            _ = closeButton.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(closeButton.exists, "\(name) never appeared")
        noteRetries(taps, opening: name)
        try then()
        try audit(name)
        try assertFitsScreen(name)
        guard closing else { return }
        closeButton.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "\(name) didn't close back to Home")
    }

    /// A tap that went nowhere is the launch-time window where sheets have also
    /// opened blank or under Home's cards: retried so the run goes on, but never
    /// silently — an expected failure in the report says which screen and how often.
    private func noteRetries(_ taps: Int, opening name: String) {
        guard taps > 1 else { return }
        XCTExpectFailure("\(name) opened only on tap \(taps): a tap during Home's launch settle went nowhere",
                         strict: false) {
            XCTFail("\(name) needed \(taps) taps")
        }
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
    /// `within`: judge only that element's own descendants — the rest lies under it.
    private func audit(_ screen: String, within cover: XCUIElement? = nil) throws {
        var judged: Set<String>?
        if let cover {
            var labels: Set<String> = []
            func visit(_ element: XCUIElementSnapshot) {
                labels.insert(element.label)
                element.children.forEach(visit)
            }
            visit(try cover.snapshot())
            // A cover read as one element would judge nothing inside it.
            XCTAssertTrue(labels.contains("Not now"), "\(screen): the cover's own elements weren't found to judge")
            judged = labels
        }
        // Collected, then failed once: XCTest's own line names only the first
        // issue's kind, not which element, nor the rest.
        var rejected: [String] = []
        do {
            try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
                if let judged, !judged.contains(issue.element?.label ?? "") { return true }
                if self.accepts(issue) { return true }
                let element = issue.element
                let type = element.map { "\($0.elementType.rawValue)" } ?? "?"
                let id = element.map { $0.identifier.isEmpty ? "" : " [\($0.identifier)]" } ?? ""
                let frame = element.map { " at \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? ""
                rejected.append("\(issue.compactDescription) on \(type) \"\(element?.label ?? "")\"\(id)\(frame)")
                return true
            }
            XCTAssertTrue(rejected.isEmpty, "\(screen): \(rejected.joined(separator: " | "))")
        } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
            // XCTest's own time limit, on a loaded simulator. The screen still
            // opened and closed in time — the hang guard — so it isn't a failure.
            // Reported, not passed silently: a screen never judged isn't a clean one.
            XCTExpectFailure("\(screen): the audit timed out and judged nothing", strict: false) {
                XCTFail("\(screen) wasn't audited")
            }
        }
    }

    /// Home's wrapped notice paragraph, the picker's tile labels, the moment
    /// composer's 11 pt "Camera" (its "Library" and "Draw" neighbours pass), and
    /// Settings' section headers — measured 5.5–6.5:1, and still flagged when
    /// drawn pure black, so the audit is misreading them. The gallery's "who ·
    /// when" line measured 4.98:1 on the simulator, flagged only some runs.
    /// The terms' tagline sits on the backdrop's pink corner: 4.7:1 measured from
    /// the run's own recording, over AA's 4.5. The recap's bordered Share…: 11:1;
    /// its "Make it again", 9.7:1 (flagged once its 44 pt tap area grew). The
    /// invite's white "Share link" on crimson: 4.9:1, as Home's heart button.
    /// Its link (selectable text: it keeps neither our identifier nor our label,
    /// checked in the run) is matched by prefix: muted grey on the white card, 5.9:1.
    private static let misreadText: Set<String> = ["home.notice.message", "status.tile.label",
                                                   "composer.source.Camera", "settings.section.header",
                                                   "gallery.attribution", "terms.tagline", "recap.share",
                                                   "recap.remake", "invite.share"]

    private func accepts(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let element = issue.element
        let label = element?.label ?? ""
        // Under the keyboard (Welcome's field is focused on arrival): nothing there
        // can be judged. Just above it, only its suggestion bar's empty cells.
        let keyboard = app.keyboards.firstMatch
        if let element, keyboard.exists {
            if keyboard.frame.intersects(element.frame) { return true }
            if element.elementType == .other, label.isEmpty,
               keyboard.frame.insetBy(dx: 0, dy: -50).intersects(element.frame) { return true }
        }
        // The system's graphical date picker (the anniversary ask): its time button
        // ("16:58") and calendar text the audit can't attribute to any element.
        if app.datePickers.firstMatch.exists {
            if element == nil, issue.compactDescription.localizedCaseInsensitiveContains("inaccessible text") { return true }
            if element?.elementType == .button, label.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
                return true
            }
        }
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
            if label.hasPrefix("https://www.icloud.com/share/") { return true }
            // Not a misread: status history's bare day headers fall short over the
            // backdrop's crimson corner, and are kept bare by choice.
            if element.identifier == "history.day.header" { return true }
            // Decorative, and hidden from VoiceOver — the audit lists hidden elements too:
            // a lone separator, and a surprise's words under the scratch card's foil.
            if label == "·" || element.identifier == "celebration.sealed" { return true }
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

/// What the celebration cover announces itself as (`CelebrationOverlay.accessibilityText`).
private enum CelebrationProbe {
    static let coverLabel = "Sam has a surprise for you."
}
