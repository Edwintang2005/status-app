import UserNotifications
import XCTest

/// Per-kind notification levels: a push is made quieter, never louder, and
/// never dropped — the quietest level still files it.
final class NotificationPreferencesTests: XCTestCase {
    private func preferences(statuses: NotificationPreferences.Level = .sound,
                             hearts: NotificationPreferences.Level = .sound,
                             pictures: NotificationPreferences.Level = .sound,
                             voiceMemos: NotificationPreferences.Level = .sound) -> NotificationPreferences {
        var preferences = NotificationPreferences()
        preferences.statuses = statuses
        preferences.hearts = hearts
        preferences.pictures = pictures
        preferences.voiceMemos = voiceMemos
        return preferences
    }

    func testEveryKindStartsWithSound() {
        let defaults = NotificationPreferences()
        XCTAssertEqual([defaults.statuses, defaults.hearts, defaults.pictures, defaults.voiceMemos],
                       [.sound, .sound, .sound, .sound])
    }

    /// A value this build can't read costs that kind only.
    func testDecodingFallsBackFieldByField() throws {
        let decoded = try JSONDecoder().decode(NotificationPreferences.self,
                                               from: Data(#"{"hearts":"list","pictures":"shout"}"#.utf8))
        XCTAssertEqual(decoded.hearts, .list)
        XCTAssertEqual(decoded.pictures, .sound, "unknown value")
        XCTAssertEqual(decoded.statuses, .sound, "missing key")
    }

    func testEachPushReadsItsKind() {
        let prefs = preferences(statuses: .silent, hearts: .list, pictures: .silent, voiceMemos: .list)
        XCTAssertEqual(prefs.level(for: .status), .silent)
        XCTAssertEqual(prefs.level(for: .nudge), .list)
        XCTAssertEqual(prefs.level(for: .moment, momentKinds: [.voice]), .list)
        XCTAssertEqual(prefs.level(for: .moment, momentKinds: [.drawing]), .silent)
        XCTAssertNil(prefs.level(for: .other))
    }

    /// A burst rings if any of its kinds would; with nothing read, the louder of the two.
    func testAMomentPushTakesTheLoudestKind() {
        let prefs = preferences(pictures: .sound, voiceMemos: .list)
        XCTAssertEqual(prefs.level(for: .moment, momentKinds: [.voice, .photo]), .sound)
        XCTAssertEqual(prefs.level(for: .moment), .sound, "unread: never quieter than either choice")
        XCTAssertEqual(preferences(pictures: .list, voiceMemos: .silent).level(for: .moment), .silent)
    }

    func testAPlanIsOnlyEverMadeQuieter() {
        let loud = PushBannerPolicy.Plan(title: "Sam", volume: .timeSensitive, sound: true)
        XCTAssertEqual(loud.limited(to: .sound), loud)
        XCTAssertEqual(loud.limited(to: nil), loud)

        let silent = loud.limited(to: .silent)
        XCTAssertEqual(silent.volume, .silent, "a banner, not breaking through Focus")
        XCTAssertFalse(silent.sound)
        XCTAssertEqual(silent.title, "Sam", "the words stay")

        XCTAssertEqual(loud.limited(to: .list).volume, .quiet)
        XCTAssertEqual(PushBannerPolicy.Plan(volume: .quiet).limited(to: .silent).volume, .quiet,
                       "already quieter than asked")
    }

    /// The partner's status sound (the silent subscription's) goes when they're set silent.
    func testAQuietenedStatusLosesItsAddedSound() {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.theirs = Fixtures.status()
        let status = Fixtures.status("☕️", "coffee", at: Fixtures.date(20))
        let plan = PushBannerPolicy.decide(.status, result: RefreshResult(partnerStatus: status, newPartnerMoments: []),
                                           index: [], reportedAt: nil, in: &snapshot, now: Fixtures.date(1_000))
        XCTAssertTrue(plan.sound)
        XCTAssertFalse(plan.limited(to: preferences(statuses: .silent).level(for: .status)).sound)
    }

    func testContentIsLimitedTheSameWay() {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.limit(to: .silent)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertNil(content.userInfo[NotificationCategory.listOnlyKey])

        content.limit(to: .list)
        XCTAssertEqual(content.interruptionLevel, .passive)
        XCTAssertNotNil(content.userInfo[NotificationCategory.listOnlyKey], "the open app lists it")

        let untouched = UNMutableNotificationContent()
        untouched.sound = .default
        untouched.limit(to: .sound)
        XCTAssertNotNil(untouched.sound)
    }

    /// Per device, kept in the store every process reads.
    func testPreferencesPersistInTheSharedStore() {
        let store = SharedStore(defaults: temporaryDefaults())
        XCTAssertEqual(store.notificationPreferences, NotificationPreferences())
        store.notificationPreferences = preferences(hearts: .silent)
        XCTAssertEqual(store.notificationPreferences.hearts, .silent)
        store.clearPairing(keepingName: false)
        XCTAssertEqual(store.notificationPreferences.hearts, .silent, "an unlink keeps per-device settings")
    }
}
