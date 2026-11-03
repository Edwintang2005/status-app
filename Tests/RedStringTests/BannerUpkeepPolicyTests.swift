import XCTest

/// What a later pass does with banners already delivered (`BannerUpkeepPolicy`):
/// reword the ones a locked phone couldn't, add a picture that missed the
/// deadline, withdraw what's gone, keep only the latest status.
final class BannerUpkeepPolicyTests: XCTestCase {
    private func banner(_ id: String, _ subject: BannerSubject, held: Bool = false,
                        wantsAttachment: Bool = false, at seconds: TimeInterval = 0,
                        body: String = "") -> BannerUpkeepPolicy.Banner {
        BannerUpkeepPolicy.Banner(id: id, subject: subject, held: held,
                                  wantsAttachment: wantsAttachment, date: Fixtures.date(seconds), body: body)
    }

    private func state(index: [Moment]? = [], held: Set<String> = [], hidden: Set<String> = [],
                       attached: Set<String> = [], statusHeld: Bool = false,
                       partnerStatus: StatusPayload? = Fixtures.status(),
                       nothingUnannounced: Bool = false,
                       wordings: @escaping (Moment) -> [String] = { _ in [] }) -> BannerUpkeepPolicy.State {
        BannerUpkeepPolicy.State(index: index, heldMomentIDs: held, hidden: hidden,
                                 hasAttachment: { attached.contains($0.id) },
                                 statusHeld: statusHeld, partnerStatus: partnerStatus,
                                 nothingUnannounced: nothingUnannounced, wordings: wordings)
    }

    func testSubjectsSurviveTheirStamp() {
        for subject in [BannerSubject.moment("abc-123"), .status, .hearts, .newMoments] {
            XCTAssertEqual(BannerSubject(stamp: subject.stamp), subject)
        }
        XCTAssertNil(BannerSubject(stamp: "moment:"))
        XCTAssertNil(BannerSubject(stamp: "something-newer"))
        XCTAssertNil(BannerSubject(userInfo: ["aps": [:]]), "CloudKit's own banners carry none")
    }

    /// The point of it all: a locked phone's "Sam sent a photo" gets the real words.
    func testAHeldMomentBannerIsRewordedOnceReadable() {
        let moment = Fixtures.moment("m1")
        let actions = BannerUpkeepPolicy.plan([banner("b1", .moment("m1"), held: true)],
                                              state: state(index: [moment]))
        XCTAssertEqual(actions, [.reword(id: "b1", moment: moment)])
    }

    func testAHeldMomentStillUnreadableIsLeftAlone() {
        let actions = BannerUpkeepPolicy.plan([banner("b1", .moment("m1"), held: true)],
                                              state: state(index: [], held: ["m1"]))
        XCTAssertTrue(actions.isEmpty, "not filed yet is not gone")
    }

    /// Deleted (or cleared) before this phone could ever read it: no longer held, never filed.
    func testAHeldMomentThatIsNoLongerHeldOrFiledIsWithdrawn() {
        let actions = BannerUpkeepPolicy.plan([banner("b1", .moment("m1"), held: true)],
                                              state: state(index: [], held: []))
        XCTAssertEqual(actions, [.remove("b1")])
    }

    /// The service's own push says it again: the earlier banner for that moment goes.
    func testAnIncomingBannerForTheSameMomentReplacesTheDeliveredOne() {
        let moment = Fixtures.moment("m1")
        let actions = BannerUpkeepPolicy.plan([banner("b1", .moment("m1"), held: true), banner("b2", .moment("m2"))],
                                              state: state(index: [moment, Fixtures.moment("m2")]),
                                              incoming: .moment("m1"))
        XCTAssertEqual(actions, [.remove("b1")])
    }

    /// A rewrite is the announcement: once, and never over one already made.
    func testARewordClaimsTheMomentOnce() {
        var snapshot = Snapshot.empty
        let moment = Fixtures.moment("m1", at: Fixtures.date(30))
        XCTAssertTrue(BannerUpkeepPolicy.claimReword(moment, in: &snapshot))
        XCTAssertTrue(snapshot.hasAnnounced("m1"))
        XCTAssertEqual(snapshot.lastAnnouncedMomentSentAt, moment.sentAt, "the index fallback won't re-announce it")
        XCTAssertFalse(BannerUpkeepPolicy.claimReword(moment, in: &snapshot), "a second pass withdraws instead")
    }

    func testAMissingPictureIsAddedOnceItLands() {
        let moment = Fixtures.moment("m1")
        let waiting = [banner("b1", .moment("m1"), wantsAttachment: true)]
        XCTAssertTrue(BannerUpkeepPolicy.plan(waiting, state: state(index: [moment])).isEmpty)
        XCTAssertEqual(BannerUpkeepPolicy.plan(waiting, state: state(index: [moment], attached: ["m1"])),
                       [.refresh(id: "b1", moment: moment)])
    }

    /// Deleted, cleared by a fresh start, or reported: nothing of it stays in Notification Centre.
    func testAGoneOrReportedMomentsBannerIsWithdrawn() {
        let kept = Fixtures.moment("kept")
        let reported = Fixtures.moment("reported")
        let actions = BannerUpkeepPolicy.plan(
            [banner("b1", .moment("deleted")), banner("b2", .moment("reported")), banner("b3", .moment("kept"))],
            state: state(index: [kept, reported], hidden: ["reported"]))
        XCTAssertEqual(actions, [.remove("b1"), .remove("b2")])
    }

    func testAnUnreadableIndexTouchesNoMomentBanner() {
        let actions = BannerUpkeepPolicy.plan([banner("b1", .moment("m1")), banner("b2", .moment("m2"), held: true)],
                                              state: state(index: nil))
        XCTAssertTrue(actions.isEmpty, "unreadable isn't empty: nothing is judged gone")
    }

    func testOnlyTheNewestStatusBannerStays() {
        let actions = BannerUpkeepPolicy.plan(
            [banner("new", .status, at: 20), banner("old", .status, at: 10), banner("h", .hearts)],
            state: state())
        XCTAssertEqual(actions, [.remove("old")])
    }

    /// The service's own push supersedes every status banner already shown.
    func testAnIncomingStatusSupersedesEveryDeliveredOne() {
        let actions = BannerUpkeepPolicy.plan([banner("a", .status, held: true, at: 10), banner("b", .status, at: 20)],
                                              state: state(), incoming: .status)
        XCTAssertEqual(actions, [.remove("a"), .remove("b")])
    }

    func testAHeldStatusBannerGetsTheWordsOnceReadable() {
        let status = Fixtures.status("😴", "asleep")
        let held = [banner("s", .status, held: true)]
        XCTAssertEqual(BannerUpkeepPolicy.plan(held, state: state(partnerStatus: status)),
                       [.rewordStatus(id: "s", status: status, superseded: [])])
        XCTAssertTrue(BannerUpkeepPolicy.plan(held, state: state(statusHeld: true, partnerStatus: status)).isEmpty,
                      "still unreadable: the stored status is the previous one")
    }

    /// A generic banner may be our own status coming back: the one holding
    /// theirs goes only once the reword proves it news (`BannerUpkeep` removes
    /// `superseded` on a claim, else the generic one and all but the newest older).
    func testAHeldStatusBannerSupersedesOnlyThroughItsReword() {
        let status = Fixtures.status("🏋️", "at the gym")
        let banners = [banner("theirs", .status, at: 10), banner("generic", .status, held: true, at: 20)]
        XCTAssertEqual(BannerUpkeepPolicy.plan(banners, state: state(partnerStatus: status)),
                       [.rewordStatus(id: "generic", status: status, superseded: ["theirs"])])
        XCTAssertTrue(BannerUpkeepPolicy.plan(banners, state: state(statusHeld: true, partnerStatus: status)).isEmpty,
                      "unreadable yet: the older banner isn't judged superseded")
    }

    /// CloudKit's words for a moment push: gone once a refresh shows nothing
    /// was left to announce (an edit, a deletion, our own send).
    func testAGenericMomentBannerGoesOnceNothingIsUnannounced() {
        let generic = [banner("g", .newMoments)]
        XCTAssertTrue(BannerUpkeepPolicy.plan(generic, state: state(nothingUnannounced: false)).isEmpty,
                      "something new is still to come: the app's post replaces it")
        XCTAssertEqual(BannerUpkeepPolicy.plan(generic, state: state(nothingUnannounced: true)), [.remove("g")])
        XCTAssertTrue(BannerUpkeepPolicy.plan(generic, state: state(index: nil, nothingUnannounced: true)).isEmpty)
    }

    /// An edit another pass filed: the banner still showing the old caption gets the new one.
    func testABannerWithAnOutdatedCaptionIsRefreshed() {
        let moment = Fixtures.moment("m1")
        let wordings: (Moment) -> [String] = { _ in ["new words", "edited a caption: new words"] }
        XCTAssertEqual(BannerUpkeepPolicy.plan([banner("b1", .moment("m1"), body: "old words")],
                                               state: state(index: [moment], wordings: wordings)),
                       [.refresh(id: "b1", moment: moment)])
        for current in ["new words", "edited a caption: new words"] {
            XCTAssertTrue(BannerUpkeepPolicy.plan([banner("b1", .moment("m1"), body: current)],
                                                  state: state(index: [moment], wordings: wordings)).isEmpty)
        }
    }
}
