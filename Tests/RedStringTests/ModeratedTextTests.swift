import XCTest

/// The presentation helpers' placeholder flag: what a surface draws muted, and
/// whether it may offer "Show hidden text" (invariant 20).
final class ModeratedTextTests: XCTestCase {
    func testAStatusThatSaysReportedIsStillTheirWords() {
        let status = Fixtures.status("🙂", ContentFilter.reportedPlaceholder)
        let shown = status.moderation(reportedAt: nil, filterEnabled: true)
        XCTAssertEqual(shown.message, ModeratedText(text: ContentFilter.reportedPlaceholder, isPlaceholder: false))
        XCTAssertEqual(shown.emoji, "🙂")
        XCTAssertFalse(shown.isReported)

        let hiddenWords = Fixtures.status("🙂", ContentFilter.hiddenPlaceholder)
        XCTAssertFalse(hiddenWords.moderation(reportedAt: nil, filterEnabled: true).message.isPlaceholder)
    }

    func testAReportedStatusIsAPlaceholderWithoutItsEmoji() {
        let status = Fixtures.status("🖕", "fine words", at: Fixtures.t0)
        let shown = status.moderation(reportedAt: Fixtures.t0, revealed: true, filterEnabled: false)
        XCTAssertTrue(shown.isReported)
        XCTAssertTrue(shown.message.isPlaceholder, "revealing is for the filter, never a report")
        XCTAssertEqual(shown.message.text, ContentFilter.reportedPlaceholder)
        XCTAssertEqual(shown.emoji, "💭")
    }

    func testAFilteredStatusShowsItsWordsOnlyOnceRevealed() {
        let status = Fixtures.status("😤", "fuck this")
        let hidden = status.moderation(reportedAt: nil, filterEnabled: true)
        XCTAssertTrue(hidden.isFiltered)
        XCTAssertEqual(hidden.message, ModeratedText(text: ContentFilter.hiddenPlaceholder, isPlaceholder: true))
        XCTAssertEqual(hidden.emoji, "😤", "the filter is word-level")

        let revealed = status.moderation(reportedAt: nil, revealed: true, filterEnabled: true)
        XCTAssertTrue(revealed.isFiltered, "still revealable-from: the reveal action knows it applies")
        XCTAssertEqual(revealed.message, ModeratedText(text: "fuck this", isPlaceholder: false))

        let off = status.moderation(reportedAt: nil, filterEnabled: false)
        XCTAssertEqual(off, .shown("😤", "fuck this"))
    }

    func testModeratedAndWordsShownAgreeWithModeration() {
        let rude = Fixtures.status("😤", "fuck this")
        XCTAssertEqual(rude.moderated(reportedAt: nil, filteredText: "Hidden", filterEnabled: true).message, "Hidden")
        XCTAssertFalse(rude.wordsShown(reportedAt: nil, revealed: false, filterEnabled: true))
        XCTAssertTrue(rude.wordsShown(reportedAt: nil, revealed: true, filterEnabled: true))
    }

    func testHistoryEntriesCarryTheFlag() {
        let theirs = StatusHistoryEntry(emoji: "🙂", message: ContentFilter.reportedPlaceholder,
                                        isCelebration: false, at: Fixtures.t0, fromMe: false)
        XCTAssertFalse(theirs.moderation(reportedAt: nil, filterEnabled: true).message.isPlaceholder)
        XCTAssertTrue(theirs.moderation(reportedAt: Fixtures.t0, filterEnabled: true).message.isPlaceholder)

        let mine = StatusHistoryEntry(emoji: "😤", message: "fuck this",
                                      isCelebration: false, at: Fixtures.t0, fromMe: true)
        XCTAssertEqual(mine.moderation(reportedAt: Fixtures.t0, filterEnabled: true), .shown("😤", "fuck this"))
    }

    func testCaptionsHideAndRevealOnlyThePartners() {
        var theirs = Fixtures.moment("m1")
        theirs.caption = "what the fuck"
        XCTAssertEqual(theirs.moderatedCaption(revealed: false, filterEnabled: true),
                       ModeratedText(text: ContentFilter.hiddenPlaceholder, isPlaceholder: true))
        XCTAssertEqual(theirs.moderatedCaption(revealed: true, filterEnabled: true),
                       ModeratedText(text: "what the fuck", isPlaceholder: false))
        XCTAssertNil(theirs.displayCaption(filterEnabled: true), "hidden reads as no caption")
        XCTAssertEqual(theirs.displayCaption(filterEnabled: false), "what the fuck")

        var mine = Fixtures.moment("m2", fromMe: true)
        mine.caption = "what the fuck"
        XCTAssertEqual(mine.displayCaption(filterEnabled: true), "what the fuck")
        XCTAssertNil(Fixtures.moment("m3").moderatedCaption(revealed: false, filterEnabled: true))
    }

    func testSenderNameAndPartnerNameTakeTheSwitch() {
        var theirs = Fixtures.moment("m1")
        theirs.senderName = "cunt"
        XCTAssertEqual(theirs.displaySenderName(fallback: "Partner", filterEnabled: true), "Partner")
        XCTAssertEqual(theirs.displaySenderName(fallback: "Partner", filterEnabled: false), "cunt")

        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status()
        XCTAssertEqual(snapshot.partnerName(filterEnabled: true), "Sam")
        snapshot.theirs?.displayName = "cunt"
        XCTAssertEqual(snapshot.partnerName(filterEnabled: true), String(localized: "Partner"))
        XCTAssertEqual(snapshot.partnerName(filterEnabled: false), "cunt")
    }
}
