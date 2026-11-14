import XCTest

/// What a later pass does with banners already delivered (`BannerUpkeepPolicy`):
/// reword the ones a locked phone couldn't, add a picture that missed the
/// deadline, withdraw what's gone, keep every status banner.
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
                       caughtUp: Bool = true,
                       nothingUnannounced: Bool = false,
                       wordings: @escaping (Moment) -> [String] = { _ in [] }) -> BannerUpkeepPolicy.State {
        BannerUpkeepPolicy.State(index: index, heldMomentIDs: held, hidden: hidden,
                                 hasAttachment: { attached.contains($0.id) },
                                 statusHeld: statusHeld, partnerStatus: partnerStatus,
                                 caughtUp: caughtUp, nothingUnannounced: nothingUnannounced,
                                 wordings: wordings)
    }

    // MARK: State and banners as a pass reads them

    private func made(heldNames: [String], caughtUp: Bool = true, owed: [Moment] = [],
                      filterEnabled: Bool = false) -> BannerUpkeepPolicy.State {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status()
        snapshot.owedMoments = owed
        return .make(role: .owner, snapshot: snapshot, heldNames: heldNames, caughtUp: caughtUp,
                     index: [], hidden: [], filterEnabled: filterEnabled, hasAttachment: { _ in false })
    }

    /// Still owing records, a pass isn't caught up, whatever its own fetch said;
    /// only the partner's held records count as theirs.
    func testAStateIsMadeFromWhatIsStillHeld() {
        let partner = PairRole.participant
        let held = made(heldNames: [partner.momentRecordName(id: "m1"), PairRole.owner.momentRecordName(id: "mine"),
                                    partner.statusRecordName])
        XCTAssertFalse(held.caughtUp)
        XCTAssertEqual(held.heldMomentIDs, ["m1"])
        XCTAssertTrue(held.statusHeld)
        XCTAssertNotNil(held.partnerStatus)

        let clear = made(heldNames: [])
        XCTAssertTrue(clear.caughtUp)
        XCTAssertFalse(clear.statusHeld)
        XCTAssertFalse(made(heldNames: [], caughtUp: false).caughtUp, "the pass's own verdict stands")
    }

    func testNothingUnannouncedMeansNothingOwed() {
        XCTAssertTrue(made(heldNames: []).nothingUnannounced)
        XCTAssertFalse(made(heldNames: [], owed: [Fixtures.moment("m1")]).nothingUnannounced)
    }

    /// A stale banner's words are judged through the filter like every surface.
    func testWordingsGoThroughTheFilter() {
        var moment = Fixtures.moment("m1", fromMe: false)
        moment.caption = "fuck yes"
        XCTAssertFalse(made(heldNames: [], filterEnabled: true).wordings(moment).contains("fuck yes"))
        XCTAssertTrue(made(heldNames: [], filterEnabled: false).wordings(moment).contains("fuck yes"))
    }

    func testABannerIsReadFromItsStamp() {
        let info: [AnyHashable: Any] = [BannerSubject.key: BannerSubject.moment("m1").stamp,
                                        NotificationCategory.heldBannerKey: NotificationCategory.moment,
                                        BannerSubject.wantsAttachmentKey: true]
        let read = BannerUpkeepPolicy.Banner(id: "b", userInfo: info, isPush: false, subscriptionID: nil,
                                             date: Fixtures.t0, body: "words")
        XCTAssertEqual(read, banner("b", .moment("m1"), held: true, wantsAttachment: true, body: "words"))
    }

    /// The service never ran: CloudKit's own words on a status or moment push
    /// are inferred and held; anything else unstamped is none of upkeep's business.
    func testAnUnstampedBannerIsInferredOnlyFromAPushInCloudKitsWords() {
        let status = BannerUpkeepPolicy.Banner(id: "s", userInfo: [:], isPush: true,
                                               subscriptionID: CloudSync.SubscriptionID.status,
                                               date: Fixtures.t0, body: CloudSync.GenericAlert.status)
        XCTAssertEqual(status?.subject, .status)
        XCTAssertEqual(status?.held, true)
        XCTAssertNil(BannerUpkeepPolicy.Banner(id: "l", userInfo: [:], isPush: false,
                                               subscriptionID: CloudSync.SubscriptionID.status,
                                               date: Fixtures.t0, body: CloudSync.GenericAlert.status),
                     "a local banner")
        XCTAssertNil(BannerUpkeepPolicy.Banner(id: "w", userInfo: [:], isPush: true,
                                               subscriptionID: CloudSync.SubscriptionID.status,
                                               date: Fixtures.t0, body: "Your status was sent to Sam."),
                     "a worded echo")
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

    /// A rewrite is the announcement: an owed moment is taken, so nothing else
    /// announces it; never over a banner already made about it.
    func testARewordTakesAnOwedMomentAndNeverDoublesABanner() {
        var snapshot = Snapshot.empty
        let moment = Fixtures.moment("m1", at: Fixtures.date(30))
        snapshot.owe([moment])
        XCTAssertTrue(BannerUpkeepPolicy.claimReword(moment, in: &snapshot))
        XCTAssertTrue(snapshot.owedMoments.isEmpty, "the app won't post it again")
        XCTAssertTrue(snapshot.hasTaken("m1"))

        // Taken silently with a burst whose newest got the banner: its own,
        // already alerted, banner keeps its place, now worded.
        XCTAssertTrue(BannerUpkeepPolicy.claimReword(moment, in: &snapshot))
        // The subject of another banner: withdrawn, never two for one moment.
        snapshot.lastNotifiedMomentID = "m1"
        XCTAssertFalse(BannerUpkeepPolicy.claimReword(moment, in: &snapshot))
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

    /// Together they're the unread history: neither a newer banner nor the
    /// service's own push withdraws an older one.
    func testEveryStatusBannerStays() {
        let banners = [banner("new", .status, at: 20), banner("old", .status, at: 10), banner("h", .hearts)]
        XCTAssertTrue(BannerUpkeepPolicy.plan(banners, state: state()).isEmpty)
        XCTAssertTrue(BannerUpkeepPolicy.plan(banners, state: state(), incoming: .status).isEmpty)
    }

    func testAHeldStatusBannerGetsTheWordsOnceReadable() {
        let status = Fixtures.status("😴", "asleep")
        let held = [banner("s", .status, held: true)]
        XCTAssertEqual(BannerUpkeepPolicy.plan(held, state: state(partnerStatus: status)),
                       [.rewordStatus(id: "s", status: status, generic: false)])
        XCTAssertTrue(BannerUpkeepPolicy.plan(held, state: state(statusHeld: true, partnerStatus: status)).isEmpty,
                      "still unreadable: the stored status is the previous one")
    }

    /// The stored status is the latest, so only the newest held banner can take
    /// its words; an older one keeps "updated their status", and a worded one
    /// newer than any held banner leaves them all be.
    func testOnlyTheNewestHeldStatusBannerIsReworded() {
        let status = Fixtures.status("🏋️", "at the gym")
        let older = [banner("first", .status, held: true, at: 10), banner("second", .status, held: true, at: 20)]
        XCTAssertEqual(BannerUpkeepPolicy.plan(older, state: state(partnerStatus: status)),
                       [.rewordStatus(id: "second", status: status, generic: false)])
        let worded = older + [banner("worded", .status, at: 30)]
        XCTAssertTrue(BannerUpkeepPolicy.plan(worded, state: state(partnerStatus: status)).isEmpty)
    }

    /// CloudKit's words may be our own status coming back: `BannerUpkeep`
    /// withdraws a generic one whose reword doesn't claim, and keeps one that named them.
    func testAGenericStatusBannerIsMarkedSo() {
        let status = Fixtures.status("🏋️", "at the gym")
        let generic = banner("g", .status, held: true, body: CloudSync.GenericAlert.status)
        XCTAssertEqual(BannerUpkeepPolicy.plan([generic], state: state(partnerStatus: status)),
                       [.rewordStatus(id: "g", status: status, generic: true)])
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

    /// The index only knows what's been fetched: a failed or partial pass, or a
    /// photo still held unreadable, leaves the banner — it may be that very moment.
    func testAGenericMomentBannerStaysUntilCaughtUpWithNothingHeld() {
        let generic = [banner("g", .newMoments)]
        XCTAssertTrue(BannerUpkeepPolicy.plan(generic, state: state(caughtUp: false, nothingUnannounced: true)).isEmpty,
                      "the expanded banner's pre-fetch pass mustn't remove itself")
        XCTAssertTrue(BannerUpkeepPolicy.plan(generic, state: state(held: ["m1"], nothingUnannounced: true)).isEmpty,
                      "a held photo is exactly what it may be about")
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

    // MARK: Banners left in CloudKit's own words

    /// A push the service never worded is worked out from its subscription,
    /// only while it still shows CloudKit's own words.
    func testACloudKitWordedPushIsInferredFromItsSubscription() {
        XCTAssertEqual(BannerUpkeepPolicy.inferredSubject(subscriptionID: CloudSync.SubscriptionID.status,
                                                          body: CloudSync.GenericAlert.status), .status)
        XCTAssertEqual(BannerUpkeepPolicy.inferredSubject(subscriptionID: CloudSync.SubscriptionID.moment,
                                                          body: CloudSync.GenericAlert.moment), .newMoments)
        XCTAssertNil(BannerUpkeepPolicy.inferredSubject(subscriptionID: CloudSync.SubscriptionID.status,
                                                        body: "Your status was sent to Sam."),
                     "worded — our own echo — is left alone")
        XCTAssertNil(BannerUpkeepPolicy.inferredSubject(subscriptionID: CloudSync.SubscriptionID.nudge,
                                                        body: CloudSync.GenericAlert.nudge),
                     "a heart is swept when the app posts it")
        XCTAssertNil(BannerUpkeepPolicy.inferredSubject(subscriptionID: CloudSync.SubscriptionID.moment,
                                                        body: CloudSync.GenericAlert.status),
                     "another kind's words don't count")
        XCTAssertNil(BannerUpkeepPolicy.inferredSubject(subscriptionID: nil, body: CloudSync.GenericAlert.status))
    }

    /// Older banners in CloudKit's words say nothing and may be our own status
    /// echoing: they go once the newest is judged; one that named them stays.
    func testOlderGenericStatusBannersGoOnceTheNewestIsJudged() {
        let status = Fixtures.status("🏖️", "beach day")
        let banners = [banner("generic", .status, held: true, at: 10, body: CloudSync.GenericAlert.status),
                       banner("named", .status, held: true, at: 20, body: "updated their status"),
                       banner("newest", .status, held: true, at: 30)]
        XCTAssertEqual(BannerUpkeepPolicy.plan(banners, state: state(partnerStatus: status)),
                       [.rewordStatus(id: "newest", status: status, generic: false), .remove("generic")])
        XCTAssertTrue(BannerUpkeepPolicy.plan(banners, state: state(statusHeld: true, partnerStatus: status)).isEmpty,
                      "nothing is judged while the newest can't be read")
    }
}
