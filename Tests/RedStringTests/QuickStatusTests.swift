import CloudKit
import XCTest

/// A status set from Siri or the widget, and what Siri says.
@MainActor
final class QuickStatusTests: XCTestCase {
    private func makeStore(paired: Bool = true) -> (SharedStore, StatusHistoryLog) {
        let store = SharedStore(defaults: temporaryDefaults())
        if paired {
            store.pairing = PairingInfo(role: .owner, zoneName: AppConfig.coupleZoneName,
                                        zoneOwnerName: "__defaultOwner__", pairedAt: Fixtures.t0)
        }
        store.mutate {
            $0.isPaired = paired
            $0.mine = Fixtures.status("🌙", "night", at: Fixtures.t0, nudges: 3)
        }
        return (store, StatusHistoryLog(fileURL: temporaryFile("status-log.json"), onCorrupt: {}))
    }

    func testAQuickStatusShowsAtOnceAndSends() async {
        let (store, log) = makeStore()
        let backend = FakeBackend()
        let failure = await QuickStatus.set(emoji: "☕️", message: "  coffee  ", store: store, statusLog: log,
                                            backend: { backend })
        XCTAssertNil(failure)
        XCTAssertEqual(store.snapshot.mine?.emoji, "☕️")
        XCTAssertEqual(store.snapshot.mine?.message, "coffee", "trimmed, as the picker would")
        XCTAssertFalse(store.snapshot.myStatusPublished, "only the backend marks it sent, against what's current then")
        XCTAssertEqual(backend.published.map(\.payload.message), ["coffee"])
        XCTAssertEqual(log.load().first?.message, "coffee")
    }

    func testAdoptingKeepsTheStoresHeart() {
        var snapshot = Snapshot.empty
        snapshot.mine = Fixtures.status("🌙", "night", at: Fixtures.t0, nudges: 3)
        // Composed before a heart from the lock screen landed.
        let payload = StatusPayload.composed(emoji: "☕️", message: "coffee", after: Fixtures.status(at: Fixtures.t0))
        snapshot.adoptOwnStatus(payload, paired: true)
        XCTAssertEqual(snapshot.mine?.nudgeCount, 3)
        XCTAssertEqual(snapshot.mine?.message, "coffee")
        XCTAssertFalse(snapshot.myStatusPublished)
    }

    func testOneThatCantSendIsKeptOwed() async {
        let (store, log) = makeStore()
        let backend = FakeBackend()
        backend.fail("publish", with: CKError(.networkUnavailable))
        let failure = await QuickStatus.set(emoji: "☕️", message: "coffee", store: store, statusLog: log,
                                            backend: { backend })
        XCTAssertNotNil(failure)
        XCTAssertEqual(store.snapshot.mine?.emoji, "☕️", "still shown")
        XCTAssertFalse(store.snapshot.myStatusPublished, "owed (invariant 11)")

        // The widget's next refresh sends it, without the app.
        let resent = await QuickStatus.sendOwed(store: store, backend: { backend })
        XCTAssertTrue(resent)
        XCTAssertEqual(backend.published.last?.payload.message, "coffee")
        XCTAssertTrue(store.snapshot.myStatusPublished)
        let again = await QuickStatus.sendOwed(store: store, backend: { backend })
        XCTAssertFalse(again, "nothing owed now")
    }

    func testAComposedStatusIsStampedAfterTheLast() {
        let mine = Fixtures.status(at: Fixtures.t0)
        let next = StatusPayload.composed(emoji: "☕️", message: "x", after: mine, now: Fixtures.t0)
        XCTAssertGreaterThan(next.updatedAt, mine.updatedAt, "two in one second still order")
        XCTAssertEqual(next.displayName, mine.displayName)
        let long = StatusPayload.composed(emoji: "☕️", message: String(repeating: "a", count: 500), after: nil)
        XCTAssertEqual(long.message.count, AppConfig.statusMessageMaxLength)
    }

    // MARK: What Siri heard

    private let choices: [SpokenStatus.Choice] = [("☕️", "Coffee break"), ("😴", "Sleeping"),
                                                  ("🏠", "Home"), ("😴", "Sleeping in")]

    func testSiriTakesYourWordsAsOneStatus() {
        XCTAssertEqual(SpokenStatus.match("sleeping.", among: choices)?.message, "Sleeping", "not a list with Sleeping in")
        XCTAssertEqual(SpokenStatus.match("Café break", among: [("☕️", "Cafe break")])?.emoji, "☕️")
        XCTAssertEqual(SpokenStatus.match("I'm on a coffee break", among: choices)?.message, "Coffee break")
        XCTAssertEqual(SpokenStatus.match("coffee", among: choices)?.message, "Coffee break")
        XCTAssertEqual(SpokenStatus.match("🏠", among: choices)?.message, "Home")
    }

    func testWordsThatArentYoursBecomeTheStatus() {
        let new = SpokenStatus.match("stuck in traffic.", among: choices)
        XCTAssertEqual(new?.emoji, "💬")
        XCTAssertEqual(new?.message, "Stuck in traffic")
        XCTAssertNil(SpokenStatus.match("  ", among: choices))
    }

    // MARK: Spoken lines

    private func snapshot(_ theirs: StatusPayload?) -> Snapshot {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.theirs = theirs
        return snapshot
    }

    func testSiriSaysTheirStatusAndWhen() {
        let line = SpokenLines.partnerStatus(in: snapshot(Fixtures.status("😴", "asleep", at: Fixtures.t0)),
                                             reportedAt: nil, filterEnabled: true,
                                             now: Fixtures.t0.addingTimeInterval(20 * 60))
        XCTAssertTrue(line.hasPrefix("Sam: 😴 asleep, "), line)
        XCTAssertTrue(line.contains("20 minutes ago"), line)
    }

    func testSiriNeverSaysWhatTheScreenWouldHide() {
        let theirs = Fixtures.status("😤", "this is bullshit", at: Fixtures.t0)
        let reported = SpokenLines.partnerStatus(in: snapshot(theirs), reportedAt: Fixtures.t0, filterEnabled: true)
        XCTAssertFalse(reported.contains("bullshit"))
        XCTAssertTrue(reported.contains("hidden"), reported)
        let filtered = SpokenLines.partnerStatus(in: snapshot(theirs), reportedAt: nil, filterEnabled: true)
        XCTAssertFalse(filtered.contains("bullshit"), filtered)

        var sealed = snapshot(theirs)
        sealed.theirs?.isCelebration = true
        sealed.theirs?.celebrationStyle = .reveal
        let surprise = SpokenLines.partnerStatus(in: sealed, reportedAt: nil, filterEnabled: false)
        XCTAssertFalse(surprise.contains("bullshit"), "a surprise stays sealed")
        XCTAssertTrue(surprise.contains("surprise"), surprise)
        let reportedSurprise = SpokenLines.partnerStatus(in: sealed, reportedAt: Fixtures.t0, filterEnabled: false)
        XCTAssertTrue(reportedSurprise.contains("hidden"), "a report outranks a surprise, as on Home")
    }

    func testSiriSaysWhenThereIsNoOne() {
        XCTAssertTrue(SpokenLines.partnerStatus(in: .empty, reportedAt: nil, filterEnabled: true).contains("not linked"))
        XCTAssertTrue(SpokenLines.partnerStatus(in: snapshot(nil), reportedAt: nil, filterEnabled: true)
            .contains("hasn't set a status"))
    }

    func testSiriCountsTheDaysTogether() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let began = Anniversary(startsAt: calendar.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 23, minute: 2))!,
                                timeZoneID: "Australia/Sydney")
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 12))!
        XCTAssertEqual(SpokenLines.together(began, now: now), "You've been together 173 days. 6 months in 9 days.")
        let day = calendar.date(from: DateComponents(year: 2026, month: 12, day: 5, hour: 9))!
        XCTAssertTrue(SpokenLines.together(began, now: day).hasPrefix("Happy 6 months!"))
        XCTAssertTrue(SpokenLines.together(nil).contains("haven't set your date"))
        // 100 days lands at 11:02 pm on 13 September: until then, it's still to come.
        let hundred = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 9))!
        XCTAssertEqual(SpokenLines.together(began, now: hundred), "You've been together 99 days. 100 days later today.")
    }
}
