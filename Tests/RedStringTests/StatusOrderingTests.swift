import CloudKit
import XCTest

/// Which copy of a status wins, and what a status keeps across renames and
/// re-deliveries (invariants 13, 14, 16, 20): the rename echo, server-time
/// ordering, the sender's save decision, nudge fields another process wrote,
/// and a recreated nudge counter.
final class StatusOrderingTests: XCTestCase {
    /// "missing you" set at t0 by Sam, renamed to Sammy at +100.
    private var renamed: StatusPayload {
        var payload = Fixtures.status("🥰", "missing you", at: Fixtures.t0)
        payload.displayName = "Sammy"
        payload.wordsSince = Fixtures.t0
        payload.updatedAt = Fixtures.date(100)
        return payload
    }

    // MARK: The rename echo

    func testARenamesOwnEchoKeepsWhenTheWordsBegan() {
        let echo = Fixtures.statusRecord(.owner, name: "Sammy", at: Fixtures.date(100))
        let payload = CloudSync.payload(from: echo, nudge: nil, existing: renamed, fromPartner: false)
        XCTAssertEqual(payload?.wordsAt, Fixtures.t0, "the same version: nothing new about the words")
    }

    /// The partner's phone, re-fetching the same version (a resync, a token expiry).
    func testAReDeliveryKeepsAReportedStatusHiddenAndACelebrationPlayed() {
        var held = renamed
        held.isCelebration = true
        let again = Fixtures.statusRecord(name: "Sammy", at: Fixtures.date(100))
        again.encryptedValues[CloudSync.Field.isCelebration] = 1
        let payload = CloudSync.payload(from: again, nudge: nil, existing: held)
        XCTAssertEqual(payload?.moderated(reportedAt: Fixtures.t0, filterEnabled: false).message,
                       ContentFilter.reportedPlaceholder, "reported by its words' date: still hidden")

        var snapshot = Snapshot.empty
        snapshot.theirs = payload
        snapshot.lastCelebratedAt = Fixtures.t0
        XCTAssertNil(snapshot.pendingCelebration, "played once, not again")
    }

    func testTheFoldKeepsTheWordsDateForTheSameVersion() {
        var snapshot = Snapshot.empty
        snapshot.mine = renamed
        snapshot.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: Fixtures.date(50))
        var echo = renamed
        echo.wordsSince = nil  // as a parse without the held copy reads it
        RefreshDelta(mine: echo).fold(into: &snapshot)
        XCTAssertEqual(snapshot.mine?.wordsAt, Fixtures.t0)
        XCTAssertEqual(snapshot.myStatusSeenAt, Fixtures.date(50), "\"Seen …\" survives the rename")
    }

    /// A second rename must not log the same words again (a duplicate in both histories).
    func testRenamingTwiceDoesNotLogTheWordsAgain() {
        var snapshot = Snapshot.empty
        snapshot.mine = renamed
        snapshot.myStatusLoggedAt = Fixtures.t0
        let echo = CloudSync.payload(from: Fixtures.statusRecord(.owner, name: "Sammy", at: Fixtures.date(100)),
                                     nudge: nil, existing: renamed, fromPartner: false)
        RefreshDelta(mine: echo).fold(into: &snapshot)
        XCTAssertEqual(snapshot.myStatusLoggedAt, snapshot.mine?.wordsAt, "the next rename's `logged` is false")
    }

    func testTheStatusReceiptIsStampedByTheWords() {
        var snapshot = Snapshot.empty
        XCTAssertTrue(snapshot.stampPartnerStatusSeen(renamed, at: Fixtures.date(200)))
        XCTAssertEqual(snapshot.partnerStatusSeen?.statusUpdatedAt, Fixtures.t0)
        var again = renamed
        again.displayName = "Sam"
        again.updatedAt = Fixtures.date(300)
        XCTAssertFalse(snapshot.stampPartnerStatusSeen(again, at: Fixtures.date(400)),
                       "a rename isn't new words: no fresh \"seen just now\"")
    }

    // MARK: Server-time ordering

    /// The partner's clock ran three hours fast for one status, then was fixed.
    func testThePartnersStatusIsOrderedByServerSaveTime() {
        var snapshot = Snapshot.empty
        var fast = Fixtures.status("🎮", "gaming", at: Fixtures.date(3 * 3_600))
        fast.serverSavedAt = Fixtures.t0
        snapshot.theirs = fast
        var fixed = Fixtures.status("🍜", "lunch", at: Fixtures.date(1_800))
        fixed.serverSavedAt = Fixtures.date(1_800)
        RefreshDelta(theirs: fixed).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.message, "lunch", "saved later on the server: newer, whatever its stamp")

        var stale = fast
        stale.serverSavedAt = Fixtures.date(-60)
        RefreshDelta(theirs: stale).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.message, "lunch", "an out-of-order older copy still loses")
    }

    func testTheSavedTimeIsReadFromTheRecordInWholeSeconds() {
        let record = Fixtures.statusRecord(name: "Sam", at: Fixtures.t0)
        let payload = CloudSync.payload(from: record, nudge: nil, existing: nil, savedAt: Fixtures.date(0.7))
        XCTAssertEqual(payload?.serverSavedAt, Fixtures.t0)
    }

    func testAStatusBannerIsClaimedByServerTime() {
        var snapshot = Snapshot.empty
        var fast = Fixtures.status("🎮", "gaming", at: Fixtures.date(3 * 3_600))
        fast.serverSavedAt = Fixtures.t0
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: fast, in: &snapshot), .update)
        var fixed = Fixtures.status("🍜", "lunch", at: Fixtures.date(1_800))
        fixed.serverSavedAt = Fixtures.date(1_800)
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: fixed, in: &snapshot), .update)
        XCTAssertNil(AnnouncementPolicy.claimStatusBanner(for: fixed, in: &snapshot), "once")
    }

    func testTheSaveDecision() {
        let now = Fixtures.date(10_000)
        let mine = Fixtures.status("🍜", "lunch", at: Fixtures.date(9_990))
        func decide(_ server: StatusPayload?) -> StatusSavePolicy.Decision {
            StatusSavePolicy.decide(server: server, payload: mine, now: now)
        }
        XCTAssertEqual(decide(nil), .save)
        XCTAssertEqual(decide(mine), .alreadySaved, "a republish of what's there writes nothing")
        XCTAssertEqual(decide(Fixtures.status("☕", "coffee", at: Fixtures.date(9_995))), .superseded,
                       "set later on another device: theirs stands")
        XCTAssertEqual(decide(Fixtures.status("🎮", "gaming", at: now.addingTimeInterval(3 * 3_600))), .save,
                       "stamped ahead of this phone's present: a fast clock wrote it, ours is newer")
        XCTAssertEqual(decide(Fixtures.status("☕", "coffee", at: Fixtures.date(9_000))), .save)
        XCTAssertEqual(decide(Fixtures.status("☕", "coffee", at: mine.updatedAt)), .save,
                       "the same second, other words: ours is written")
    }

    func testASupersededSaveAdoptsTheServersStatus() {
        var snapshot = Snapshot.empty
        var mine = Fixtures.status("🍜", "lunch", at: Fixtures.t0, nudges: 4)
        mine.lastNudgeAt = Fixtures.date(-5)
        snapshot.mine = mine
        snapshot.myStatusPublished = false
        let server = Fixtures.status("☕", "coffee", at: Fixtures.date(30))
        snapshot.adoptSupersedingStatus(server, over: mine)
        XCTAssertEqual(snapshot.mine?.message, "coffee")
        XCTAssertEqual(snapshot.mine?.nudgeCount, 4, "the nudge counter is ours, not the status record's")
        XCTAssertTrue(snapshot.myStatusPublished)
        XCTAssertEqual(snapshot.myStatusLoggedAt, server.wordsAt)

        var edited = Snapshot.empty
        edited.mine = Fixtures.status("🌙", "night", at: Fixtures.date(60))
        edited.myStatusPublished = false
        edited.adoptSupersedingStatus(server, over: mine)
        XCTAssertEqual(edited.mine?.message, "night", "a newer local edit publishes on its own")
        XCTAssertFalse(edited.myStatusPublished)
    }

    // MARK: Nudge fields another process wrote

    func testAPublishKeepsTheStoresNudgeFields() {
        var snapshot = Snapshot.empty
        let built = Fixtures.status("🍜", "lunch", at: Fixtures.t0, nudges: 3)
        var current = built
        current.nudgeCount = 4
        current.lastNudgeAt = Fixtures.date(5)
        snapshot.mine = current  // the lock-screen heart landed after `built` was made
        snapshot.myStatusPublished = false
        snapshot.recordPublished(built, savedAt: Fixtures.date(7.4))
        XCTAssertEqual(snapshot.mine?.nudgeCount, 4)
        XCTAssertEqual(snapshot.mine?.lastNudgeAt, Fixtures.date(5))
        XCTAssertEqual(snapshot.mine?.serverSavedAt, Fixtures.date(7))
        XCTAssertTrue(snapshot.myStatusPublished)
    }

    func testALatePublishNeverRevertsANewerStatus() {
        var snapshot = Snapshot.empty
        snapshot.mine = Fixtures.status("🌙", "night", at: Fixtures.date(60))
        snapshot.myStatusPublished = false
        snapshot.recordPublished(Fixtures.status("🍜", "lunch", at: Fixtures.t0), savedAt: nil)
        XCTAssertEqual(snapshot.mine?.message, "night")
        XCTAssertFalse(snapshot.myStatusPublished)
    }

    func testAnUnloggedFirstStatusStaysOwedAcrossARelaunch() throws {
        var snapshot = Snapshot.empty
        snapshot.mine = renamed
        snapshot.myStatusPublished = true
        snapshot.myStatusLoggedAt = nil
        let data = try JSONEncoder.shared.encode(snapshot)
        let decoded = try JSONDecoder.shared.decode(Snapshot.self, from: data)
        XCTAssertNil(decoded.myStatusLoggedAt, "a written null is owed, not the pre-field upgrade")
        RefreshDelta(mine: renamed).fold(into: &snapshot)
        XCTAssertNil(snapshot.myStatusLoggedAt, "the echo doesn't claim the log landed")
    }

    func testAPreFieldSnapshotStillSeedsTheLoggedMark() throws {
        var snapshot = Snapshot.empty
        snapshot.mine = renamed
        snapshot.myStatusPublished = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.shared.encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "myStatusLoggedAt")
        let decoded = try JSONDecoder.shared.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.myStatusLoggedAt, renamed.wordsAt)
    }

    func testAnUnpublishedLocalStatusIsNeverRevertedByTheServerCopy() {
        var snapshot = Snapshot.empty
        let local = Fixtures.status("☕️", "coffee", at: Fixtures.date(100))
        snapshot.mine = local
        snapshot.myStatusPublished = false
        // A fast clock stamped the server copy hours ahead.
        let server = Fixtures.status("🌙", "late", at: Fixtures.date(100 + 3 * 3600))
        RefreshDelta(mine: server).fold(into: &snapshot, now: Fixtures.date(200))
        XCTAssertEqual(snapshot.mine?.message, "coffee")
    }

    // MARK: A recreated nudge counter

    func testARecreatedNudgeCounterIsTakenAsItIs() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status(nudges: 100)
        snapshot.lastSeenPartnerNudgeCount = 100
        snapshot.partnerNudgeCreatedAt = Fixtures.t0
        let rejoined = Fixtures.status(nudges: 1)
        RefreshDelta(theirs: rejoined, partnerNudgeCreatedAt: Fixtures.date(500)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 1)
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 0)
        XCTAssertEqual(snapshot.partnerNudgeCreatedAt, Fixtures.date(500))

        let previous = snapshot.theirs
        let claims = AnnouncementPolicy.claim(RefreshResult(partnerStatus: rejoined), previousStatus: previous, in: &snapshot)
        XCTAssertTrue(claims.nudge, "their first heart since rejoining is announced")
    }

    func testALateOlderCounterChangesNothing() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status(nudges: 3)
        snapshot.lastSeenPartnerNudgeCount = 3
        snapshot.partnerNudgeCreatedAt = Fixtures.date(500)
        RefreshDelta(theirs: Fixtures.status(nudges: 90), partnerNudgeCreatedAt: Fixtures.t0).fold(into: &snapshot)
        XCTAssertEqual(snapshot.partnerNudgeCreatedAt, Fixtures.date(500))
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 3)
    }

    func testTheSameCounterKeepsItsMaximum() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status(nudges: 7)
        snapshot.lastSeenPartnerNudgeCount = 7
        RefreshDelta(theirs: Fixtures.status(nudges: 3), partnerNudgeCreatedAt: Fixtures.t0).fold(into: &snapshot)
        XCTAssertEqual(snapshot.partnerNudgeCreatedAt, Fixtures.t0, "first sight only records it")
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 7)
        RefreshDelta(theirs: Fixtures.status(nudges: 5), partnerNudgeCreatedAt: Fixtures.t0).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 7, "never backwards on the same counter")
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 7)
    }

    func testADeletedCounterResetsTheWatermark() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status(nudges: 9)
        snapshot.lastSeenPartnerNudgeCount = 9
        snapshot.partnerNudgeCreatedAt = Fixtures.t0
        RefreshDelta(partnerNudgeErased: true).fold(into: &snapshot)
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 0)
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 0)
        XCTAssertNil(snapshot.partnerNudgeCreatedAt)
    }

    func testTheCountersCreationAndDeletionAreReadFromTheDelta() {
        let nudge = CKRecord(recordType: CloudSync.RecordType.nudge,
                             recordID: CKRecord.ID(recordName: PairRole.participant.nudgeRecordName, zoneID: Fixtures.zone))
        nudge[CloudSync.Field.count] = 1 as CKRecordValue
        var metadata = RecordMetadata.server
        metadata.firstSavedAt = { _ in Fixtures.date(42.9) }
        let parsed = ParsedDelta.parse(records: [nudge], deletedIDs: [], mineRole: .owner, hidden: [], metadata: metadata)
        let fold = parsed.outcome(mineRole: .owner, previousMine: nil, previousTheirs: Fixtures.status(),
                                  minePublished: true, alreadyKnown: [], hidden: []).fold
        XCTAssertEqual(fold.partnerNudgeCreatedAt, Fixtures.date(42))

        let deleted = ParsedDelta.parse(records: [], deletedIDs: [nudge.recordID], mineRole: .owner, hidden: [])
        XCTAssertTrue(deleted.outcome(mineRole: .owner, previousMine: nil, previousTheirs: nil, minePublished: true,
                                      alreadyKnown: [], hidden: []).fold.partnerNudgeErased)
        let recreated = ParsedDelta.parse(records: [nudge], deletedIDs: [nudge.recordID], mineRole: .owner, hidden: [])
        XCTAssertFalse(recreated.theirNudgeErased, "the record that exists now wins")
    }

    // MARK: Verification round: whole-second ties and unreadable server copies

    func testATieInServerTimeFallsBackToTheStamps() {
        var snapshot = Snapshot.empty
        var newer = Fixtures.status("🌙", "late", at: Fixtures.date(200))
        newer.serverSavedAt = Fixtures.date(1_000)
        snapshot.theirs = newer
        // Saved in the same whole second, delivered out of order.
        var older = Fixtures.status("☕️", "early", at: Fixtures.date(100))
        older.serverSavedAt = Fixtures.date(1_000)
        RefreshDelta(theirs: older).fold(into: &snapshot, now: Fixtures.date(2_000))
        XCTAssertEqual(snapshot.theirs?.message, "late", "a tie must not let the older copy win")
    }

    func testATieInServerTimeStillAnnouncesALaterStatus() {
        var snapshot = Snapshot.empty
        var first = Fixtures.status("☕️", "early", at: Fixtures.date(100))
        first.serverSavedAt = Fixtures.date(1_000)
        XCTAssertNotNil(AnnouncementPolicy.claimStatusBanner(for: first, in: &snapshot, now: Fixtures.date(2_000)))
        var second = Fixtures.status("🌙", "late", at: Fixtures.date(200))
        second.serverSavedAt = Fixtures.date(1_000)
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: second, in: &snapshot, now: Fixtures.date(2_000)), .update,
                       "the tie falls back to the stamps, which say it's newer")
        XCTAssertNil(AnnouncementPolicy.claimStatusBanner(for: first, in: &snapshot, now: Fixtures.date(2_000)),
                     "and the earlier one, re-delivered, isn't news")
    }

    func testAnUnreadableServerCopyIsNeverAdoptedNorOverwrittenWhileNewer() {
        let now = Fixtures.date(10_000)
        let ours = Fixtures.status("☕️", "coffee", at: Fixtures.date(9_000))
        let unreadableNewer = Fixtures.status("💭", "", at: Fixtures.date(9_500))
        XCTAssertEqual(StatusSavePolicy.decide(server: unreadableNewer, serverReadable: false, payload: ours, now: now),
                       .unreadableNewer)
        let unreadableOlder = Fixtures.status("💭", "", at: Fixtures.date(8_000))
        XCTAssertEqual(StatusSavePolicy.decide(server: unreadableOlder, serverReadable: false, payload: ours, now: now),
                       .save, "an older copy is overwritten whatever its words")
        let unreadableFast = Fixtures.status("💭", "", at: Fixtures.date(10_000 + 6 * 3600))
        XCTAssertEqual(StatusSavePolicy.decide(server: unreadableFast, serverReadable: false, payload: ours, now: now),
                       .save, "a stamp past this phone's present is a fast clock, overwritten as before")
        // Readable, the existing rules are unchanged.
        XCTAssertEqual(StatusSavePolicy.decide(server: unreadableNewer, payload: ours, now: now), .superseded)
    }
}
