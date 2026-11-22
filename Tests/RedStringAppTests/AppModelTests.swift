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
