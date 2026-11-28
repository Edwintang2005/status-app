import CloudKit
import XCTest

/// `AppModel` over fakes: its own stores and backend, no App Group, no UIKit.
@MainActor
final class AppModelTests: XCTestCase {
    private func file(_ moments: [Moment], in stores: CloudStores, model: AppModel) {
        stores.index.insert(moments)
        stores.shared.refreshDerived(index: stores.index)
        model.reload()
    }

    func testASetStatusShowsAtOnceThenPublishes() async {
        let (model, backend, stores) = makeModel()
        let failure = await model.setStatus(emoji: "☕️", message: "  coffee?  ")
        XCTAssertNil(failure)
        XCTAssertEqual(model.snapshot.mine?.message, "coffee?", "trimmed")
        XCTAssertEqual(backend.published.map(\.payload.emoji), ["☕️"])
        XCTAssertEqual(stores.statusLog.load().first?.message, "coffee?", "logged on this phone")
    }

    func testAStatusThatCantSendIsKeptOwed() async {
        let (model, backend, stores) = makeModel()
        backend.fail("publish", with: CKError(.networkUnavailable))
        let failure = await model.setStatus(emoji: "🌙", message: "night")
        XCTAssertEqual(failure, .offline)
        XCTAssertEqual(model.snapshot.mine?.emoji, "🌙", "still shown")
        XCTAssertTrue(backend.published.isEmpty)
        XCTAssertFalse(stores.shared.snapshot.myStatusPublished, "owed (invariant 11)")
        // The outbox's next pass sends it: it was kept, not dropped.
        let sent = await model.outbox.republishStatus()
        XCTAssertTrue(sent)
        XCTAssertEqual(backend.published.map(\.payload.emoji), ["🌙"])
    }

    func testMarkingAPartnerMomentSeenOwesItsReceipt() async {
        let (model, _, stores) = makeModel()
        let photo = Fixtures.moment("p1", seen: false)
        file([photo], in: stores, model: model)
        stores.shared.mutate { $0.receiptsDirty = false }

        model.markSeen(photo)
        XCTAssertTrue(model.history.first { $0.id == "p1" }?.seen == true, "the screen updates at once")
        await waitUntil { stores.shared.snapshot.receiptsDirty }
        XCTAssertTrue(stores.index.load().first { $0.id == "p1" }?.seen == true, "and the index")
    }

    func testOwnMomentsAreNeverMarkedSeen() async {
        let (model, _, stores) = makeModel()
        let own = Fixtures.moment("o1", fromMe: true, seen: false)
        file([own], in: stores, model: model)
        stores.shared.mutate { $0.receiptsDirty = false }
        model.markSeen(own)
        XCTAssertFalse(model.history.first { $0.id == "o1" }?.seen == true)
        XCTAssertFalse(stores.shared.snapshot.receiptsDirty)
    }

    func testHidingTheWidgetsPictureShowsTheOneBefore() async {
        let (model, _, stores) = makeModel()
        file([Fixtures.moment("old", at: Fixtures.date(-60)), Fixtures.moment("new")], in: stores, model: model)
        XCTAssertEqual(model.snapshot.latestPartnerVisualMoment?.id, "new")
        await model.setShownInWidget(Fixtures.moment("new"), false)
        XCTAssertEqual(model.snapshot.latestPartnerVisualMoment?.id, "old")
        XCTAssertEqual(model.widgetPictureState(of: Fixtures.moment("new")).hidden, true)
        await model.setShownInWidget(Fixtures.moment("new"), true)
        XCTAssertEqual(model.snapshot.latestPartnerVisualMoment?.id, "new")
    }

    func testTheScreenSleepsOnlyOnceNothingHoldsIt() async {
        let awake = Box<[Bool]>([])
        let stores = makeStores()
        var environment = AppEnvironment.detached
        environment.keepScreenAwake = { awake.value.append($0) }
        let model = AppModel(stores: stores, backend: FakeAppBackend(), environment: environment)
        model.keepAwake(.archive, true)
        model.keepAwake(.recap, true)
        model.keepAwake(.archive, false)
        XCTAssertEqual(awake.value.last, true, "the recap still holds it")
        model.keepAwake(.recap, false)
        XCTAssertEqual(awake.value.last, false)
    }

    func testUnlinkingHereClearsThisModelsOwnStores() async {
        let (model, _, stores) = makeModel()
        file([Fixtures.moment("p1")], in: stores, model: model)
        stores.shared.mutate { $0.theirs = Fixtures.status() }
        model.forceLocalReset(startingOver: false)
        XCTAssertFalse(model.isPaired)
        XCTAssertTrue(stores.index.load().isEmpty, "the injected index, not the App Group's")
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.invite.url)
    }
}

/// The milestone day on Home (A1).
@MainActor
final class MilestoneDayTests: XCTestCase {
    func testTheDayShowsOnHomeUntilWavedAwayAndItsHeartsRiseOnce() throws {
        let (model, _, stores) = makeModel()
        // Six calendar months ago, in this phone's own zone: today is the mark.
        let began = Anniversary(startsAt: Calendar.current.date(byAdding: .month, value: -6, to: Date())!,
                                timeZoneID: TimeZone.current.identifier)
        // On the 29th to 31st, six months back can clamp to a shorter month and miss today.
        try XCTSkipUnless(began.milestoneToday(Date())?.mark == .months(6), "no six-month mark lands today")
        stores.shared.mutate { $0.anniversary = began }
        model.reload()

        let day = try XCTUnwrap(model.milestoneOnHome())
        XCTAssertEqual(day.title, "6 months")
        XCTAssertTrue(model.claimMilestoneCelebration(day), "the first time it shows")
        XCTAssertFalse(model.claimMilestoneCelebration(day), "and only that once")

        model.dismissMilestoneNotice(day)
        XCTAssertNil(model.milestoneOnHome(), "waved away for the day")
    }

    func testNoDateNoDay() {
        let (model, _, _) = makeModel()
        XCTAssertNil(model.milestoneOnHome())
    }

    /// Waved away after midnight: it's the card that was shown that goes, not
    /// whatever today is by then.
    func testNotNowActsOnTheDayItWasShownFor() {
        let (model, _, _) = makeModel()
        let shown = HomeNotice.MilestoneDay(title: "6 months", key: "1700000000:6")
        model.dismissMilestoneNotice(shown)
        XCTAssertEqual(model.milestoneNoticeDismissed, shown.key)
    }
}

/// The partner card's "New": their status changed since it was last on screen.
@MainActor
final class NewPartnerStatusTests: XCTestCase {
    func testAStatusThatChangedSinceItWasLastShownIsNewUntilShown() {
        let (model, _, stores) = makeModel()
        stores.shared.mutate { $0.isPaired = true; $0.theirs = Fixtures.status("😴", "asleep", at: Fixtures.t0) }
        model.reload()
        XCTAssertFalse(model.partnerStatusIsNew, "before the first look, nothing is news")
        model.markPartnerStatusShown()
        XCTAssertEqual(stores.shared.partnerStatusShownAt, Fixtures.t0)

        stores.shared.mutate { $0.theirs = Fixtures.status("☕️", "coffee", at: Fixtures.date(600)) }
        model.reload()
        XCTAssertTrue(model.partnerStatusIsNew, "changed while you were away")
        model.markPartnerStatusShown()
        XCTAssertFalse(model.partnerStatusIsNew, "shown once, not new again")
    }

    /// Local, not a receipt: it works with read receipts off and sends nothing.
    func testItWorksWithReadReceiptsOff() {
        let (model, backend, stores) = makeModel()
        model.readReceiptsEnabled = false
        stores.shared.mutate { $0.isPaired = true; $0.theirs = Fixtures.status(at: Fixtures.t0) }
        model.reload()
        model.markPartnerStatusShown()
        stores.shared.mutate { $0.theirs = Fixtures.status("☕️", "coffee", at: Fixtures.date(600)) }
        model.reload()
        XCTAssertTrue(model.partnerStatusIsNew)
        XCTAssertNil(stores.shared.snapshot.partnerStatusSeen, "no receipt stamped")
        XCTAssertTrue(backend.receipts.isEmpty)
    }

    func testAReportedStatusIsNeverNew() {
        let (model, _, stores) = makeModel()
        stores.shared.mutate { $0.isPaired = true; $0.theirs = Fixtures.status(at: Fixtures.t0) }
        model.reload()
        model.markPartnerStatusShown()
        stores.shared.mutate { $0.theirs = Fixtures.status("😤", "words", at: Fixtures.date(600)) }
        stores.shared.hiddenPartnerStatusAt = Fixtures.date(600)
        model.reload()
        XCTAssertFalse(model.partnerStatusIsNew, "its words were never on screen")
    }
}

/// Every status set while paired is owed its log record until one's confirmed.
@MainActor
final class StatusHistoryOwedTests: XCTestCase {
    func testASetStatusIsOwedItsLogUntilConfirmed() async {
        let (model, backend, stores) = makeModel()
        backend.fail("publish", with: CKError(.networkUnavailable))
        _ = await model.setStatus(emoji: "☕️", message: "coffee")
        XCTAssertEqual(stores.statusLog.load().first?.unlogged, true, "offline: owed until a log record lands")
    }
}

