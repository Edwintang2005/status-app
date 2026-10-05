import UserNotifications
import XCTest

/// Home's small decisions: the notifications-off notice (#28), the picker's
/// Recent row (#33), and when the status read receipt may be stamped (#33).
final class HomeRulesTests: XCTestCase {
    // MARK: Notifications off

    private func notice(_ authorization: UNAuthorizationStatus,
                        banners: UNAlertStyle = .banner,
                        lockScreen: UNNotificationSetting = .enabled,
                        center: UNNotificationSetting = .enabled,
                        timeSensitive: UNNotificationSetting = .enabled) -> NotificationsNotice? {
        NotificationsNotice.current(authorization: authorization, banners: banners, lockScreen: lockScreen,
                                    notificationCenter: center, timeSensitive: timeSensitive)
    }

    func testNoticeNamesWhatStopsAlerts() {
        XCTAssertEqual(notice(.denied, banners: .none, lockScreen: .disabled, center: .disabled, timeSensitive: .disabled), .off)
        XCTAssertEqual(notice(.authorized, banners: .none, lockScreen: .disabled, center: .disabled), .bannersOff)
        XCTAssertEqual(notice(.authorized, timeSensitive: .disabled), .focusBlocked)
        XCTAssertNil(notice(.authorized))
        XCTAssertNil(notice(.authorized, timeSensitive: .notSupported))
        XCTAssertNil(notice(.notDetermined, banners: .none, lockScreen: .notSupported, center: .notSupported, timeSensitive: .notSupported),
                     "the prompt is still to come")
    }

    func testBannersOffOnlyWhenNothingShowsThem() {
        XCTAssertNil(notice(.authorized, banners: .none), "the Lock Screen still shows them")
        XCTAssertNil(notice(.authorized, banners: .none, lockScreen: .disabled), "Notification Center still holds them")
        XCTAssertEqual(notice(.authorized, banners: .none, lockScreen: .disabled, center: .disabled), .bannersOff)
    }

    func testDismissalHoldsForThatProblemOnly() {
        let shown = NotificationsNotice.reconcile(current: .off, dismissed: nil)
        XCTAssertEqual(shown.shown, .off)

        let waved = NotificationsNotice.reconcile(current: .off, dismissed: .off)
        XCTAssertNil(waved.shown, "dismissed on this device")
        XCTAssertEqual(waved.dismissed, .off, "and stays dismissed while it stands")

        let different = NotificationsNotice.reconcile(current: .bannersOff, dismissed: .off)
        XCTAssertEqual(different.shown, .bannersOff, "a different problem is news")
        XCTAssertNil(different.dismissed)
    }

    func testTurningNotificationsBackOnReArmsTheNotice() {
        let fixed = NotificationsNotice.reconcile(current: nil, dismissed: .off)
        XCTAssertNil(fixed.shown)
        XCTAssertNil(fixed.dismissed, "forgotten once it's fixed")
        XCTAssertEqual(NotificationsNotice.reconcile(current: .off, dismissed: fixed.dismissed).shown, .off,
                       "so switching them off again brings it back")
    }

    // MARK: Recent statuses

    func testRecentIncludesEmojiOnlyStatusesOnceEach() {
        let log = [
            StatusHistoryEntry(emoji: "🌙", message: "", isCelebration: false, at: Fixtures.date(50), fromMe: true),
            StatusHistoryEntry(emoji: "🥰", message: "missing you", isCelebration: false, at: Fixtures.date(40), fromMe: false),
            StatusHistoryEntry(emoji: "☕️", message: "coffee", isCelebration: false, at: Fixtures.date(30), fromMe: true),
            StatusHistoryEntry(emoji: "🌙", message: "", isCelebration: false, at: Fixtures.date(20), fromMe: true),
            StatusHistoryEntry(emoji: "", message: "", isCelebration: false, at: Fixtures.date(10), fromMe: true),
            StatusHistoryEntry(emoji: "🌙", message: "goodnight", isCelebration: false, at: Fixtures.t0, fromMe: true),
        ]
        let recent = StatusHistoryEntry.recentOwn(in: log, limit: 8)
        XCTAssertEqual(recent.map { "\($0.emoji)|\($0.message)" }, ["🌙|", "☕️|coffee", "🌙|goodnight"],
                       "own only, emoji-only kept, deduped, an empty entry skipped")
        XCTAssertEqual(StatusHistoryEntry.recentOwn(in: log, limit: 2).count, 2)
    }

    // MARK: The status read receipt

    func testReceiptWaitsForWordsThatWereActuallyShown() {
        let clean = Fixtures.status("🥰", "missing you")
        XCTAssertTrue(clean.wordsShown(reportedAt: nil, revealed: false, filterEnabled: true))

        let rude = Fixtures.status("😤", "fuck this traffic")
        XCTAssertFalse(rude.wordsShown(reportedAt: nil, revealed: false, filterEnabled: true),
                       "hidden by the filter: nobody read it")
        XCTAssertTrue(rude.wordsShown(reportedAt: nil, revealed: true, filterEnabled: true), "revealed: now they have")
        XCTAssertTrue(rude.wordsShown(reportedAt: nil, revealed: false, filterEnabled: false), "filter off: shown as written")

        XCTAssertFalse(clean.wordsShown(reportedAt: clean.wordsAt, revealed: true, filterEnabled: false),
                       "a reported status is never read, revealed or not")
        XCTAssertTrue(clean.wordsShown(reportedAt: Fixtures.date(-60), revealed: false, filterEnabled: true),
                      "an older report doesn't cover a new status")
    }
}
