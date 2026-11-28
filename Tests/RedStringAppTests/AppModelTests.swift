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

    /// Looked before they'd set anything: their first status is new, and glows.
    func testTheirFirstStatusIsNew() {
        let (model, _, stores) = makeModel()
        stores.shared.mutate { $0.isPaired = true }
        model.reload()
        model.markPartnerStatusShown()
        stores.shared.mutate { $0.theirs = Fixtures.status("👋", "hi", at: Fixtures.date(60)) }
        model.reload()
        XCTAssertTrue(model.partnerStatusIsNew)
    }

    /// The next partner isn't judged against the last one's watermark.
    func testUnlinkingForgetsWhatWasShown() {
        let (model, _, stores) = makeModel()
        stores.shared.mutate { $0.isPaired = true; $0.theirs = Fixtures.status(at: Fixtures.date(9_000)) }
        model.reload()
        model.markPartnerStatusShown()
        stores.shared.clearPairing(keepingName: true)
        model.reload()
        XCTAssertNil(model.partnerStatusShownAt)
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

/// "Don't send": an unsent moment of ours, gone from this phone and owed as a delete.
@MainActor
final class CancelSendTests: XCTestCase {
    func testAnUnsentMomentCanBeTakenBack() async {
        let (model, _, stores) = makeModel()
        var photo = Fixtures.moment("p1", fromMe: true)
        photo.uploaded = false
        stores.index.insert([photo])
        model.reload()
        XCTAssertEqual(model.pendingSends.moments.map(\.id), ["p1"])

        await model.cancelSend(photo)
        XCTAssertTrue(stores.index.load().isEmpty, "off this phone")
        XCTAssertTrue(model.pendingSends.moments.isEmpty)
    }

    /// Landed while the dialog was up: still taken back, for both, inside the window.
    func testOneThatLandedMeanwhileIsDeletedForBoth() async {
        let (model, backend, stores) = makeModel()
        let shown = Fixtures.moment("p1", fromMe: true, uploaded: false)
        var landed = shown
        landed.uploaded = true
        stores.index.insert([landed])
        model.reload()
        // The dialog holds the copy the list drew, from before it landed, sent long ago.
        await model.cancelSend(shown)
        XCTAssertTrue(stores.index.load().isEmpty)
        XCTAssertEqual(backend.deleted.flatMap { $0 }, ["p1"], "and from iCloud")
        XCTAssertNil(model.errorTitle)
    }
}

/// Statuses set in the app are told to iOS, so Siri Suggestions learn your routine.
@MainActor
final class StatusDonationTests: XCTestCase {
    /// What the model told iOS; `nil` is "forget them all".
    private final class Donations: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String?] = []
        func add(_ status: StatusOption?) { lock.withLock { items.append(status.map { "\($0.emoji) \($0.message)" }) } }
        var all: [String?] { lock.withLock { items } }
    }

    private func makeModel(_ donations: Donations) -> AppModel {
        var environment = AppEnvironment.detached
        environment.donateStatus = { donations.add($0) }
        return AppModel(stores: makeStores(paired: .owner), backend: FakeAppBackend(), environment: environment)
    }

    func testAStatusSetHereIsToldToSiriButNotACelebration() async {
        let donations = Donations()
        let model = makeModel(donations)
        _ = await model.setStatus(emoji: "☕️", message: "coffee")
        _ = await model.setStatus(emoji: "🎉", message: "surprise", celebration: .confetti)
        await waitUntil { donations.all == ["☕️ coffee"] }
    }

    func testABannerReplyIsntARoutine() async {
        let donations = Donations()
        let model = makeModel(donations)
        _ = await model.setStatus(emoji: "💬", message: "see you at 7", routine: false)
        _ = await model.setStatus(emoji: "☕️", message: "coffee")
        await waitUntil { donations.all == ["☕️ coffee"] }
    }

    /// The partner ending it, seen by another process: forgotten all the same.
    func testThePartnerEndingItForgetsThemToo() async {
        let donations = Donations()
        let stores = makeStores(paired: .owner)
        var environment = AppEnvironment.detached
        environment.donateStatus = { donations.add($0) }
        let model = AppModel(stores: stores, backend: FakeAppBackend(), environment: environment)
        stores.shared.clearPairing(keepingName: true)
        model.reload()
        await waitUntil { donations.all == [nil] }
    }

    /// Statuses set for them aren't suggestions for whoever comes next.
    func testUnlinkingForgetsThem() async {
        let donations = Donations()
        let model = makeModel(donations)
        model.forceLocalReset(startingOver: false)
        await waitUntil { donations.all == [nil] }
    }
}

/// A date edit is always stamped after the last, whatever the clock says.
@MainActor
final class AnniversaryStampTests: XCTestCase {
    func testAnEditIsStampedAfterTheLastEvenWithTheClockBehind() async {
        let (model, _, stores) = makeModel()
        let ahead = Date().addingTimeInterval(3 * 3_600).wholeSeconds
        stores.shared.mutate { $0.anniversaryEditedAt = ahead }
        model.reload()
        await model.setAnniversary(Anniversary(startsAt: Fixtures.date(1_000), timeZoneID: "UTC"))
        XCTAssertGreaterThan(stores.shared.snapshot.anniversaryEditedAt!, ahead)
    }
}
