import CloudKit
import XCTest

/// How one change fetch folds into the snapshot: the newer-local status rule,
/// partner erasure, and — the anniversary bug of September 2026 — that a record
/// arriving with unreadable encrypted fields never counts as a removal.
final class RefreshDeltaTests: XCTestCase {
    private var paired: Snapshot {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.mine = Fixtures.status("💼", "working", at: Fixtures.date(100), nudges: 1)
        snapshot.theirs = Fixtures.status("🥰", "missing you", at: Fixtures.date(50))
        return snapshot
    }

    // MARK: Own status

    func testOlderServerStatusKeepsLocalTextButAdoptsNudgeCounter() {
        var snapshot = paired
        var server = Fixtures.status("☕", "coffee", at: Fixtures.date(10), nudges: 4)
        server.lastNudgeAt = Fixtures.date(90)
        RefreshDelta(mine: server).fold(into: &snapshot)
        XCTAssertEqual(snapshot.mine?.message, "working", "an offline edit is newer than the server copy")
        XCTAssertEqual(snapshot.mine?.nudgeCount, 4)
        XCTAssertEqual(snapshot.mine?.lastNudgeAt, Fixtures.date(90))
    }

    func testNewerServerStatusReplacesLocal() {
        var snapshot = paired
        let server = Fixtures.status("☕", "coffee", at: Fixtures.date(200))
        RefreshDelta(mine: server).fold(into: &snapshot)
        XCTAssertEqual(snapshot.mine?.message, "coffee")
    }

    // MARK: Partner status

    func testPartnerErasedClearsTheirs() {
        var snapshot = paired
        RefreshDelta(partnerErased: true).fold(into: &snapshot)
        XCTAssertNil(snapshot.theirs)
    }

    func testPartnerStatusArrivesAndAbsentLeavesExisting() {
        var snapshot = paired
        RefreshDelta().fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.message, "missing you")
        RefreshDelta(theirs: Fixtures.status("🎉", "party", at: Fixtures.date(300))).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.message, "party")
    }

    /// Two processes fetch concurrently and apply out of order: the stale copy
    /// must not regress the status, but its nudge counter is still server truth.
    func testOlderPartnerStatusFromAStaleDeltaKeepsTheNewerOne() {
        var snapshot = paired
        var stale = Fixtures.status("🎉", "party", at: Fixtures.date(10), nudges: 7)
        stale.lastNudgeAt = Fixtures.date(40)
        RefreshDelta(theirs: stale).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.message, "missing you")
        XCTAssertEqual(snapshot.theirs?.updatedAt, Fixtures.date(50))
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 7)
        XCTAssertEqual(snapshot.theirs?.lastNudgeAt, Fixtures.date(40))
        // Same timestamp (a nudge-only delta merged into the held status) still applies.
        RefreshDelta(theirs: Fixtures.status("🥰", "missing you", at: Fixtures.date(50), nudges: 8)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 8)
    }

    // MARK: Anniversary request

    func testAnniversaryRequestFoldsLikeTheAnniversary() {
        var snapshot = paired
        RefreshDelta(anniversaryRequestedAt: Fixtures.date(500)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversaryRequestedAt, Fixtures.date(500))
        XCTAssertTrue(snapshot.anniversaryRequestPending)
        // Unreadable: neither value nor removal.
        RefreshDelta().fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversaryRequestedAt, Fixtures.date(500))
        RefreshDelta(anniversaryRequestErased: true).fold(into: &snapshot)
        XCTAssertNil(snapshot.anniversaryRequestedAt)
        XCTAssertFalse(snapshot.anniversaryRequestPending)
    }

    func testUnpublishedRequestOutranksServerCopy() {
        var snapshot = paired
        snapshot.anniversaryRequestedAt = Fixtures.date(900)
        snapshot.anniversaryRequestPublished = false
        RefreshDelta(anniversaryRequestedAt: Fixtures.date(500)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversaryRequestedAt, Fixtures.date(900))
    }

    // MARK: Anniversary

    func testUnreadableAnniversaryRecordKeepsStoredDate() {
        var snapshot = paired
        snapshot.anniversary = Anniversary(startsAt: Fixtures.t0)
        // A record arrived but parsed to nothing: neither value nor deletion.
        RefreshDelta(anniversary: nil, anniversaryErased: false).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversary?.startsAt, Fixtures.t0)
    }

    func testDeletionClearsAnniversary() {
        var snapshot = paired
        snapshot.anniversary = Anniversary(startsAt: Fixtures.t0)
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot)
        XCTAssertNil(snapshot.anniversary)
    }

    func testReadableAnniversaryReplacesStoredDate() {
        var snapshot = paired
        snapshot.anniversary = Anniversary(startsAt: Fixtures.t0)
        RefreshDelta(anniversary: Anniversary(startsAt: Fixtures.date(3600))).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversary?.startsAt, Fixtures.date(3600))
    }

    func testUnpublishedOwnerEditOutranksServer() {
        var snapshot = paired
        snapshot.anniversary = Anniversary(startsAt: Fixtures.date(7200))
        snapshot.anniversaryPublished = false
        RefreshDelta(anniversary: Anniversary(startsAt: Fixtures.t0)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversary?.startsAt, Fixtures.date(7200))
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversary?.startsAt, Fixtures.date(7200),
                       "a stale deletion must not beat the edit about to be republished")
    }

    // MARK: Status read receipt

    func testUnreadableReceiptKeepsSeenState() {
        var snapshot = paired
        let seen = StatusSeen(statusUpdatedAt: Fixtures.date(100), seenAt: Fixtures.date(120))
        snapshot.myStatusSeenByPartner = seen
        RefreshDelta(receiptReadable: false, statusSeen: nil).fold(into: &snapshot)
        XCTAssertEqual(snapshot.myStatusSeenByPartner, seen)
    }

    func testReadableReceiptIsAuthoritativeEvenWhenEmpty() {
        var snapshot = paired
        snapshot.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.date(100), seenAt: Fixtures.date(120))
        RefreshDelta(receiptReadable: true, statusSeen: nil).fold(into: &snapshot)
        XCTAssertNil(snapshot.myStatusSeenByPartner, "receipts turned off publishes no status receipt")
        let seen = StatusSeen(statusUpdatedAt: Fixtures.date(100), seenAt: Fixtures.date(130))
        RefreshDelta(receiptReadable: true, statusSeen: seen).fold(into: &snapshot)
        XCTAssertEqual(snapshot.myStatusSeenByPartner, seen)
    }

    // MARK: Skewed clocks and nudge counters

    /// A held status stamped in the future (a clock that once ran ahead) is
    /// stale: the capped, genuinely newer copy replaces it.
    func testFutureStampedHeldStatusYields() {
        var snapshot = paired
        snapshot.theirs = Fixtures.status("🕰️", "from the future", at: Date().addingTimeInterval(3 * 86_400))
        let now = Fixtures.status("☕️", "coffee?", at: Date().addingTimeInterval(-60))
        RefreshDelta(theirs: now).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.message, "coffee?")
    }

    func testNudgeCountNeverMovesBackwards() {
        var snapshot = paired
        snapshot.theirs = Fixtures.status("🥰", "missing you", at: Fixtures.date(50), nudges: 9)
        // Newer status built from a snapshot read before another process wrote 9.
        RefreshDelta(theirs: Fixtures.status("🥰", "missing you", at: Fixtures.date(60), nudges: 7)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.theirs?.nudgeCount, 9)
    }

    func testPartnerErasedResetsNudgeWatermark() {
        var snapshot = paired
        snapshot.lastSeenPartnerNudgeCount = 12
        RefreshDelta(partnerErased: true).fold(into: &snapshot)
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 0,
                       "a rejoining participant restarts at 1; a stale mark would swallow their nudges")
    }

    // MARK: A late anniversary delete

    private var date: Anniversary { Anniversary(startsAt: Fixtures.date(1_000), timeZoneID: "UTC") }

    /// Cleared, the delete timed out, a new date was set and saved — then the
    /// old delete landed. The date goes back up instead of vanishing on both phones.
    func testOurOwnLateDeleteOverANewerDatePutsTheDateBack() {
        var snapshot = Snapshot.empty
        snapshot.anniversary = date
        snapshot.anniversaryDeleteInFlightSince = Fixtures.date(0)
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot, now: Fixtures.date(60))
        XCTAssertEqual(snapshot.anniversary, date, "kept")
        XCTAssertFalse(snapshot.anniversaryPublished, "and owed again: the outbox puts it back")
        XCTAssertNil(snapshot.anniversaryDeleteInFlightSince, "that delete has landed now")
    }

    func testADeletionWithNoneOfOursInFlightIsMeant() {
        var snapshot = Snapshot.empty
        snapshot.anniversary = date
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot)
        XCTAssertNil(snapshot.anniversary, "another of the owner's devices cleared it")
        XCTAssertTrue(snapshot.anniversaryPublished)
    }

    func testALongAgoTimedOutDeleteNoLongerCounts() {
        var snapshot = Snapshot.empty
        snapshot.anniversary = date
        snapshot.anniversaryDeleteInFlightSince = Fixtures.date(0)
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot, now: Fixtures.date(AppConfig.lateDeleteWindow + 1))
        XCTAssertNil(snapshot.anniversary)
    }

    func testOurDeleteLandingAsMeantJustSettles() {
        var snapshot = Snapshot.empty
        snapshot.anniversaryDeleteInFlightSince = Fixtures.date(0)
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot, now: Fixtures.date(60))
        XCTAssertNil(snapshot.anniversary)
        XCTAssertTrue(snapshot.anniversaryPublished)
        XCTAssertNil(snapshot.anniversaryDeleteInFlightSince)
    }

    /// A mark from the future (a clock change) is stale, not a delete of ours on its way.
    func testAFutureDeleteMarkIsStale() {
        var snapshot = Snapshot.empty
        snapshot.anniversary = date
        snapshot.anniversaryDeleteInFlightSince = Fixtures.date(10_000)
        RefreshDelta(anniversaryErased: true).fold(into: &snapshot, now: Fixtures.date(60))
        XCTAssertNil(snapshot.anniversary)
    }

    /// Another device's later stamp comes in with its date, so the next edit here beats it.
    func testAnIncomingDateBringsItsStamp() {
        var snapshot = Snapshot.empty
        snapshot.anniversaryEditedAt = Fixtures.date(100)
        RefreshDelta(anniversary: date, anniversaryEditedAt: Fixtures.date(500)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversaryEditedAt, Fixtures.date(500))
        RefreshDelta(anniversary: date, anniversaryEditedAt: Fixtures.date(300)).fold(into: &snapshot)
        XCTAssertEqual(snapshot.anniversaryEditedAt, Fixtures.date(500), "never moved back")
    }
}
