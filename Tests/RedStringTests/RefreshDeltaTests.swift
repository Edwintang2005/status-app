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

    // MARK: Anniversary

    func testUnreadableAnniversaryRecordKeepsStoredDate() {
        var snapshot = paired
        snapshot.anniversary = Anniversary(startsAt: Fixtures.t0)
        // A record arrived but parsed to nothing: neither value nor deletion.
        RefreshDelta(anniversary: nil, anniversaryErased: false, unreadableRecords: 1).fold(into: &snapshot)
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
}
