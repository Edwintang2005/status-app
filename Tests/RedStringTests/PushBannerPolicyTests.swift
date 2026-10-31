import XCTest

/// The notification service's branch table (invariant 10): every push is a
/// claim, an unclaimed one is never credited to the partner, a delta this
/// process couldn't read keeps CloudKit's words at full volume — and the
/// partner leaving, deletions and a missing nudge count are never news.
final class PushBannerPolicyTests: XCTestCase {
    private let now = Fixtures.date(1_000)

    private func decide(_ push: PushBannerPolicy.Push,
                        _ result: RefreshResult = .empty,
                        index: [Moment] = [],
                        reportedAt: Date? = nil,
                        in snapshot: inout Snapshot) -> PushBannerPolicy.Plan {
        PushBannerPolicy.decide(push, result: result, index: index, reportedAt: reportedAt, in: &snapshot, now: now)
    }

    private func paired(theirs: StatusPayload? = Fixtures.status()) -> Snapshot {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.theirs = theirs
        return snapshot
    }

    private func partnerGone() -> Snapshot {
        var snapshot = paired(theirs: Fixtures.status())
        RefreshDelta(partnerErased: true).fold(into: &snapshot, now: now)
        return snapshot
    }

    func testPushIsReadFromTheSubscription() {
        XCTAssertEqual(PushBannerPolicy.Push(subscriptionID: CloudSync.SubscriptionID.status), .status)
        XCTAssertEqual(PushBannerPolicy.Push(subscriptionID: CloudSync.SubscriptionID.nudge), .nudge)
        XCTAssertEqual(PushBannerPolicy.Push(subscriptionID: CloudSync.SubscriptionID.moment), .moment)
        XCTAssertEqual(PushBannerPolicy.Push(subscriptionID: CloudSync.SubscriptionID.legacySilentStatus), .other)
        XCTAssertEqual(PushBannerPolicy.Push(subscriptionID: nil).category, "")
        XCTAssertEqual(PushBannerPolicy.Push.moment.category, NotificationCategory.moment)
    }

    func testUnpairedIsQuietWithNoHeartToSendBack() {
        let plan = PushBannerPolicy.unpaired
        XCTAssertEqual(plan.volume, .quiet)
        XCTAssertTrue(plan.dropsCategory)
        XCTAssertEqual(plan.title, AppConfig.appName)
        XCTAssertNotEqual(plan.body, CloudSync.GenericAlert.nudge, "an ex's heart must not read as one")
    }

    func testOtherPushesAreLeftAlone() {
        var snapshot = paired()
        XCTAssertEqual(decide(.other, in: &snapshot), .unchanged)
    }

    // MARK: Moments

    func testAMomentIsClaimedOnceAndAttached() {
        var snapshot = paired()
        var moment = Fixtures.moment("m1", at: Fixtures.date(10))
        moment.caption = "morning"
        let result = RefreshResult(partnerStatus: nil, newPartnerMoments: [moment])
        let plan = decide(.moment, result, in: &snapshot)
        XCTAssertEqual(plan.title, "Sam")
        XCTAssertEqual(plan.body, "morning")
        XCTAssertEqual(plan.attachment?.id, "m1")
        XCTAssertEqual(plan.subject, .moment("m1"), "found again by a later pass")
        XCTAssertEqual(plan.volume, .asSent)
        XCTAssertTrue(snapshot.hasAnnounced("m1"))

        let again = decide(.moment, result, in: &snapshot)
        XCTAssertNil(again.attachment, "a sibling instance with the same delta must not re-describe it")
        XCTAssertEqual(again.volume, .quiet)
        XCTAssertNotEqual(again.body, CloudSync.GenericAlert.moment)
    }

    /// The push of this phone's own send coming back is never worded as the partner's.
    func testOurOwnMomentComingBackSaysSo() {
        var snapshot = paired()
        snapshot.latestPartnerMoment = Fixtures.moment("theirs", at: Fixtures.date(990))
        snapshot.recordAnnounced(snapshot.latestPartnerMoment!)
        var result = RefreshResult.empty
        result.ownMomentSent = true
        result.momentsArrived = true
        let plan = decide(.moment, result, in: &snapshot)
        XCTAssertEqual(plan.title, AppConfig.appName)
        XCTAssertEqual(plan.body, String(localized: "Your moment was sent to Sam."),
                       "a retried upload older than their newest is still ours")
        XCTAssertEqual(plan.volume, .quiet)
    }

    /// Nothing read (the widget took the delta first): ours only when it's
    /// uploaded, just sent and the newest in the space.
    func testWithNothingReadOnlyAJustSentUploadIsOurs() {
        var snapshot = paired()
        snapshot.latestPartnerMoment = Fixtures.moment("theirs", at: Fixtures.date(10))
        snapshot.latestOwnMoment = Fixtures.moment("ours", at: Fixtures.date(990), fromMe: true)
        XCTAssertEqual(decide(.moment, in: &snapshot).body, String(localized: "Your moment was sent to Sam."))

        snapshot.latestOwnMoment = Fixtures.moment("pending", at: Fixtures.date(990), fromMe: true, uploaded: false)
        XCTAssertEqual(decide(.moment, in: &snapshot).body, String(localized: "Your shared space changed."),
                       "still waiting to send: never \"sent\"")

        snapshot.latestOwnMoment = Fixtures.moment("old", at: Fixtures.date(20), fromMe: true)
        XCTAssertEqual(decide(.moment, in: &snapshot).body, String(localized: "Your shared space changed."),
                       "an old send isn't this push's")
    }

    /// Something was read, but not ours: never "sent" from the snapshot's guess.
    func testAReadDeltaWithoutOurRecordIsNotOurSend() {
        var snapshot = paired()
        snapshot.latestOwnMoment = Fixtures.moment("ours", at: Fixtures.date(990), fromMe: true)
        var result = RefreshResult.empty
        result.momentsArrived = true
        XCTAssertEqual(decide(.moment, result, in: &snapshot).body, String(localized: "Your shared space changed."))
    }

    /// Announced already (the app's refresh got there first): its words, quietly.
    func testAnAnnouncedMomentIsWordedQuietly() {
        var snapshot = paired()
        let theirs = Fixtures.moment("theirs", kind: .voice, at: Fixtures.date(20))
        snapshot.latestPartnerMoment = theirs
        snapshot.latestOwnMoment = Fixtures.moment("ours", at: Fixtures.date(10), fromMe: true)
        snapshot.recordAnnounced(theirs)
        let plan = decide(.moment, in: &snapshot)
        XCTAssertEqual(plan.title, "Sam")
        XCTAssertEqual(plan.body, Moment.Kind.voice.arrivalSummary)
        XCTAssertEqual(plan.volume, .quiet)
        XCTAssertNil(plan.attachment)
    }

    func testAnUnknownMomentChangeIsNeverCreditedToThePartner() {
        var snapshot = paired()
        snapshot.latestPartnerMoment = Fixtures.moment("unannounced", at: Fixtures.date(20))
        let plan = decide(.moment, in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "Your shared space changed."))
        XCTAssertEqual(plan.volume, .quiet)
    }

    func testAnUnreadableMomentIsWordedFromItsKindAndStampedHeld() {
        var snapshot = paired()
        var result = RefreshResult.empty
        result.unreadableRecordNames = ["moment-participant-x"]
        result.heldPartnerMomentKinds = [.photo, .voice]
        result.heldPartnerMomentIDs = ["older", "x"]
        let plan = decide(.moment, result, in: &snapshot)
        XCTAssertEqual(plan.title, "Sam")
        XCTAssertEqual(plan.body, AnnouncementPolicy.heldMomentBody(kinds: [.photo, .voice]))
        XCTAssertEqual(plan.heldCategory, NotificationCategory.moment)
        XCTAssertEqual(plan.subject, .moment("x"), "the newest, reworded once readable")
        XCTAssertEqual(plan.volume, .asSent, "real and unannounced: full volume")
    }

    func testOwnWriteFromAnotherDeviceSaysSo() {
        var snapshot = paired()
        var result = RefreshResult.empty
        result.ownRecordsChanged = true
        let plan = decide(.moment, result, in: &snapshot)
        XCTAssertEqual(plan.title, AppConfig.appName)
        XCTAssertEqual(plan.volume, .quiet)
    }

    func testDeletionsAreWordedQuietlyWithOrWithoutAFreshStart() {
        var snapshot = paired()
        var result = RefreshResult.empty
        result.removedMoments = 3
        // One batch of a big deletion: still nothing new from the partner in it.
        result.incomplete = true
        let removed = decide(.moment, result, in: &snapshot)
        XCTAssertEqual(removed.volume, .quiet)
        XCTAssertEqual(removed.body, String(localized: "Moments were removed from your shared space."))

        snapshot.freshStart.clearedBefore = Fixtures.date(5)
        let cleared = decide(.moment, result, in: &snapshot)
        XCTAssertEqual(cleared.body, String(localized: "Moments were cleared for your fresh start."))
        XCTAssertEqual(cleared.volume, .quiet)
    }

    func testDeletionsBesideAnUnreadablePartnerStatusStayLoud() {
        var snapshot = paired()
        var result = RefreshResult.empty
        result.removedMoments = 1
        result.unreadableRecordNames = ["status-participant"]
        result.heldPartnerStatus = true
        XCTAssertEqual(decide(.moment, result, in: &snapshot), .unchanged)
    }

    func testAnUnreadDeltaKeepsCloudKitsWordsAtFullVolume() {
        var snapshot = paired()
        var result = RefreshResult.empty
        result.incomplete = true
        XCTAssertEqual(decide(.moment, result, in: &snapshot), .unchanged)
        XCTAssertEqual(decide(.status, result, in: &snapshot), .unchanged)
        XCTAssertEqual(decide(.nudge, result, in: &snapshot), .unchanged)
    }

    // MARK: The partner leaving

    func testThePartnerLeavingIsSaidQuietlyOnEveryPush() {
        for push in [PushBannerPolicy.Push.status, .nudge, .moment] {
            var snapshot = partnerGone()
            var result = RefreshResult.empty
            result.partnerLeft = true
            result.removedMoments = 4
            let plan = decide(push, result, in: &snapshot)
            XCTAssertEqual(plan.title, "Sam", "the name they went by, not \"Partner\"")
            XCTAssertEqual(plan.body, String(localized: "left your shared space"))
            XCTAssertEqual(plan.volume, .quiet)
            XCTAssertTrue(plan.dropsCategory)
            XCTAssertTrue(snapshot.partnerLeftAnnounced, "claimed, so the app doesn't post it again")
        }
    }

    /// The push whose delta another process already consumed still knows.
    func testALaterPushAfterTheyLeftSaysTheSameNeverAHeart() {
        var snapshot = partnerGone()
        XCTAssertNil(snapshot.theirs)
        let plan = decide(.nudge, in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "left your shared space"))
        XCTAssertEqual(plan.volume, .quiet)
    }

    // MARK: Nudges

    func testANewHeartIsClaimedAndBreaksThroughOnce() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 2))
        snapshot.lastSeenPartnerNudgeCount = 2
        var status = Fixtures.status(nudges: 3)
        status.lastNudgeAt = now
        let result = RefreshResult(partnerStatus: status, newPartnerMoments: [])
        let plan = decide(.nudge, result, in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "is thinking of you 💭"))
        XCTAssertEqual(plan.volume, .timeSensitive)
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 3)

        let again = decide(.nudge, result, in: &snapshot)
        XCTAssertEqual(again.body, String(localized: "is thinking of you 💭"), "already announced: the words stay")
        XCTAssertEqual(again.volume, .quiet, "but it mustn't read as a second tap")
    }

    func testAStaleHeartSaysEarlier() {
        var snapshot = paired()
        var status = Fixtures.status(nudges: 1)
        status.lastNudgeAt = now.addingTimeInterval(-AppConfig.nudgeStaleAfter - 60)
        let plan = decide(.nudge, RefreshResult(partnerStatus: status, newPartnerMoments: []), in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "was thinking of you earlier 💭"))
        XCTAssertEqual(plan.volume, .active)
    }

    func testNoCountIsNeverWordedAsAHeart() {
        var snapshot = paired(theirs: nil)
        let plan = decide(.nudge, in: &snapshot)
        XCTAssertEqual(plan.title, AppConfig.appName)
        XCTAssertNotEqual(plan.body, String(localized: "is thinking of you 💭"))
        XCTAssertEqual(plan.volume, .quiet)
    }

    func testOwnNudgeFromAnotherDevice() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 1))
        snapshot.lastSeenPartnerNudgeCount = 1
        var result = RefreshResult(partnerStatus: Fixtures.status(nudges: 1), newPartnerMoments: [])
        result.ownRecordsChanged = true
        let plan = decide(.nudge, result, in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "You sent a nudge from another device."))
        XCTAssertEqual(plan.volume, .quiet)
    }

    /// The lock-screen heart's save pushes back to this phone: never their heart.
    func testOurOwnLockScreenHeartIsNotTheirs() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 1))
        snapshot.lastSeenPartnerNudgeCount = 1
        snapshot.lastNudgeSentAt = Fixtures.date(900)
        var result = RefreshResult(partnerStatus: Fixtures.status(nudges: 1), newPartnerMoments: [])
        result.ownNudgeSentAt = Fixtures.date(900)
        let plan = decide(.nudge, result, in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "Your nudge was sent to Sam."))
        XCTAssertEqual(plan.title, AppConfig.appName)
        XCTAssertEqual(plan.volume, .quiet)

        // The push beat the widget's write of the new count: still this phone's tap.
        result.ownRecordsChanged = true
        XCTAssertEqual(decide(.nudge, result, in: &snapshot).body, String(localized: "Your nudge was sent to Sam."))
    }

    func testOurOwnHeartFromAnotherDeviceSaysSo() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 1))
        snapshot.lastSeenPartnerNudgeCount = 1
        snapshot.lastNudgeSentAt = Fixtures.date(100)
        var result = RefreshResult(partnerStatus: Fixtures.status(nudges: 1), newPartnerMoments: [])
        result.ownNudgeSentAt = Fixtures.date(900)
        XCTAssertEqual(decide(.nudge, result, in: &snapshot).body,
                       String(localized: "You sent a nudge from another device."))
    }

    /// The widget's own refresh took our save before its push came: an empty
    /// delta, but the latest heart in the space is ours.
    func testAnEmptyDeltaAfterOurTapIsStillOurs() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 1))
        snapshot.theirs?.lastNudgeAt = Fixtures.date(500)
        snapshot.mine = Fixtures.status(nudges: 4)
        snapshot.mine?.lastNudgeAt = Fixtures.date(900)
        snapshot.lastSeenPartnerNudgeCount = 1
        snapshot.lastNudgeSentAt = Fixtures.date(900)
        let plan = decide(.nudge, RefreshResult(partnerStatus: snapshot.theirs, newPartnerMoments: []), in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "Your nudge was sent to Sam."))
        XCTAssertEqual(plan.volume, .quiet)
    }

    /// Their heart, already announced elsewhere, is still worded as theirs.
    func testAnEmptyDeltaAfterTheirHeartStaysTheirs() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 2))
        snapshot.theirs?.lastNudgeAt = Fixtures.date(950)
        snapshot.mine = Fixtures.status(nudges: 4)
        snapshot.mine?.lastNudgeAt = Fixtures.date(900)
        snapshot.lastSeenPartnerNudgeCount = 2
        let plan = decide(.nudge, RefreshResult(partnerStatus: snapshot.theirs, newPartnerMoments: []), in: &snapshot)
        XCTAssertEqual(plan.title, "Sam")
        XCTAssertEqual(plan.volume, .quiet)
    }

    /// A burst of slow taps lands together: an earlier one is still this phone's.
    func testAnEarlierTapOfABurstIsStillThisPhones() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 1))
        snapshot.lastSeenPartnerNudgeCount = 1
        snapshot.lastNudgeSentAt = Fixtures.date(960)
        var result = RefreshResult(partnerStatus: Fixtures.status(nudges: 1), newPartnerMoments: [])
        result.ownNudgeSentAt = Fixtures.date(900)
        XCTAssertEqual(decide(.nudge, result, in: &snapshot).body, String(localized: "Your nudge was sent to Sam."))
    }

    /// Both hearts in one delta: theirs is still announced as theirs.
    func testTheirHeartBesideOursIsStillTheirs() {
        var snapshot = paired(theirs: Fixtures.status(nudges: 1))
        snapshot.lastSeenPartnerNudgeCount = 1
        snapshot.lastNudgeSentAt = Fixtures.date(900)
        var result = RefreshResult(partnerStatus: Fixtures.status(nudges: 2), newPartnerMoments: [])
        result.ownNudgeSentAt = Fixtures.date(900)
        result.partnerNudgeArrived = true
        XCTAssertEqual(decide(.nudge, result, in: &snapshot).title, "Sam")
    }

    // MARK: Statuses

    func testAStatusUpdateIsClaimedOnce() {
        var snapshot = paired()
        let status = Fixtures.status("☕️", "coffee", at: Fixtures.date(20))
        let result = RefreshResult(partnerStatus: status, newPartnerMoments: [])
        let plan = decide(.status, result, in: &snapshot)
        XCTAssertEqual(plan.title, "Sam")
        XCTAssertEqual(plan.body, "☕️ coffee")
        XCTAssertEqual(plan.thread, "status-updates")
        XCTAssertEqual(plan.volume, .asSent)
        XCTAssertTrue(plan.sound, "the silent subscription's sound, added for the partner's status")

        snapshot.theirs = status
        let again = decide(.status, result, in: &snapshot)
        XCTAssertEqual(again.body, "☕️ coffee", "already announced: its words, never CloudKit's")
        XCTAssertEqual(again.volume, .quiet)
        XCTAssertFalse(again.sound)
    }

    /// The sound is for the partner's status only: a pass that couldn't word
    /// the push may be our own save coming back, so it stays as silent as it came.
    func testOnlyAPartnerStatusIsGivenASound() {
        var snapshot = paired()
        var held = RefreshResult.empty
        held.unreadableRecordNames = ["status-participant"]
        held.heldPartnerStatus = true
        XCTAssertTrue(decide(.status, held, in: &snapshot).sound, "their record, unreadable: still theirs")

        var unread = RefreshResult.empty
        unread.unreadableRecordNames = ["status-owner"]
        XCTAssertEqual(decide(.status, unread, in: &snapshot), .unchanged)
        XCTAssertFalse(decide(.status, unread, in: &snapshot).sound)

        var nudge = RefreshResult(partnerStatus: Fixtures.status(nudges: 1), newPartnerMoments: [])
        nudge.partnerNudgeArrived = true
        XCTAssertFalse(decide(.nudge, nudge, in: &snapshot).sound, "the nudge subscription carries its own")
    }

    /// This phone's own status save coming back: ordered by server time when both have it.
    func testOurOwnStatusComingBackSaysSo() {
        var theirs = Fixtures.status("🌙", "late", at: Fixtures.date(50))
        theirs.serverSavedAt = Fixtures.date(10)
        var snapshot = paired(theirs: theirs)
        var mine = Fixtures.status("☕️", "coffee", at: Fixtures.date(20))
        mine.serverSavedAt = Fixtures.date(20)
        snapshot.mine = mine
        let plan = decide(.status, RefreshResult(partnerStatus: theirs, newPartnerMoments: []), in: &snapshot)
        XCTAssertEqual(snapshot.lastAnnouncedPartnerStatusAt, theirs.updatedAt, "theirs, first seen, is still news")

        let echo = decide(.status, RefreshResult(partnerStatus: theirs, newPartnerMoments: []), in: &snapshot)
        XCTAssertEqual(plan.body, "🌙 late")
        XCTAssertEqual(echo.body, String(localized: "Your status was sent to Sam."))
        XCTAssertEqual(echo.volume, .quiet)
    }

    func testARenameIsWordedAsOne() {
        var snapshot = paired()
        let before = Fixtures.status(at: Fixtures.date(10))
        _ = decide(.status, RefreshResult(partnerStatus: before, newPartnerMoments: []), in: &snapshot)
        var renamed = before
        renamed.displayName = "Sammy"
        renamed.updatedAt = Fixtures.date(20)
        let plan = decide(.status, RefreshResult(partnerStatus: renamed, newPartnerMoments: []), in: &snapshot)
        XCTAssertEqual(plan.title, "Sam")
        XCTAssertEqual(plan.body, String(localized: "is now going by Sammy"))
        XCTAssertNil(plan.subject, "a new name mustn't supersede the banner holding the words")
    }

    func testAReportedStatusShowsNoWords() {
        var snapshot = paired()
        let status = Fixtures.status("☕️", "coffee", at: Fixtures.date(20))
        let plan = decide(.status, RefreshResult(partnerStatus: status, newPartnerMoments: []),
                          reportedAt: status.wordsAt, in: &snapshot)
        XCTAssertEqual(plan.body, String(localized: "updated their status"))
    }

    func testAnUnreadableStatusIsHeldNotClaimed() {
        var snapshot = paired()
        var result = RefreshResult(partnerStatus: Fixtures.status(at: Fixtures.date(30)), newPartnerMoments: [])
        result.heldPartnerStatus = true
        result.unreadableRecordNames = ["status-participant"]
        let plan = decide(.status, result, in: &snapshot)
        XCTAssertEqual(plan.heldCategory, NotificationCategory.status)
        XCTAssertEqual(plan.subject, .status)
        XCTAssertEqual(plan.volume, .asSent)
        XCTAssertNil(snapshot.lastAnnouncedPartnerStatusAt, "the previous status must not be announced as news")
    }

    // MARK: Attachment budget

    func testTheAttachmentNeverEatsTheLastSeconds() {
        XCTAssertEqual(PushBannerPolicy.attachmentDeadline(elapsed: 0), AppConfig.widgetDeadline)
        XCTAssertEqual(PushBannerPolicy.attachmentDeadline(elapsed: 20), 5)
        XCTAssertNil(PushBannerPolicy.attachmentDeadline(elapsed: 24.5))
    }

    // MARK: The app's own announcements

    func testTheAppPostsOnlyWhatItClaimed() {
        let moment = Fixtures.moment("m1")
        var status = Fixtures.status(nudges: 2)
        status.lastNudgeAt = Fixtures.date(5)
        let result = RefreshResult(partnerStatus: status, newPartnerMoments: [moment])
        let claims = AnnouncementPolicy.Claims(nudge: true, moment: moment, partnerLeft: true)
        XCTAssertEqual(PushBannerPolicy.appAnnouncements(claims, result: result, announce: true),
                       [.partnerLeft, .nudge(sentAt: Fixtures.date(5)), .moment(moment)])
        XCTAssertEqual(PushBannerPolicy.appAnnouncements(claims, result: result, announce: false), [])
        XCTAssertEqual(PushBannerPolicy.appAnnouncements(.init(), result: result, announce: true), [])
    }

    func testThePartnerLeavingIsClaimedOnceAcrossTheAppAndThePush() {
        var snapshot = partnerGone()
        var result = RefreshResult.empty
        result.partnerLeft = true
        XCTAssertTrue(AnnouncementPolicy.claim(result, previousStatus: Fixtures.status(), in: &snapshot).partnerLeft)
        XCTAssertFalse(AnnouncementPolicy.claim(result, previousStatus: nil, in: &snapshot).partnerLeft)

        var pushedFirst = partnerGone()
        _ = decide(.status, result, in: &pushedFirst)
        XCTAssertFalse(AnnouncementPolicy.claim(result, previousStatus: nil, in: &pushedFirst).partnerLeft,
                       "the push already said so")
    }
}
