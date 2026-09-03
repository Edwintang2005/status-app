import XCTest

/// `Snapshot` is the widget's cache and the announcement watermark store; an
/// old on-disk copy must decode under every newer build (CLAUDE.md invariant 5).
final class SnapshotCodableTests: XCTestCase {
    private let legacyTheirs = """
        {"emoji":"🥰","message":"missing you","displayName":"Sam",
         "updatedAt":"2026-09-01T10:00:00Z","nudgeCount":2}
        """
    private let legacyPhoto = """
        {"id":"m1","kind":"photo","caption":"","senderName":"Sam",
         "sentAt":"2026-09-01T09:00:00Z","fromMe":false}
        """

    func testLegacySnapshotDecodesWithFallbacks() throws {
        let snapshot = try decode(Snapshot.self, """
            {"isPaired":true,"lastSeenPartnerNudgeCount":2,
             "theirs":\(legacyTheirs),"latestPartnerMoment":\(legacyPhoto)}
            """)
        XCTAssertTrue(snapshot.isPaired)
        XCTAssertEqual(snapshot.theirs?.emoji, "🥰")
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 2)
        XCTAssertTrue(snapshot.myStatusPublished, "pre-field snapshots must not republish")
        XCTAssertEqual(snapshot.notifiedMomentIDs, [])
        XCTAssertFalse(snapshot.receiptsDirty)
        XCTAssertNil(snapshot.partnerStatusSeen)
        XCTAssertEqual(snapshot.latestPartnerVisualMoment?.id, "m1",
                       "absent key: legacy snapshots treat every moment as a picture")
    }

    func testLegacyVoiceMomentIsNotPromotedToVisual() throws {
        let voice = legacyPhoto.replacingOccurrences(of: "\"photo\"", with: "\"voice\"")
        let snapshot = try decode(Snapshot.self, """
            {"isPaired":true,"latestPartnerMoment":\(voice)}
            """)
        XCTAssertNil(snapshot.latestPartnerVisualMoment)
    }

    func testExplicitNullVisualMomentStaysNil() throws {
        let snapshot = try decode(Snapshot.self, """
            {"isPaired":true,"latestPartnerMoment":\(legacyPhoto),"latestPartnerVisualMoment":null}
            """)
        XCTAssertNil(snapshot.latestPartnerVisualMoment, "explicit null means the picture was deleted")
    }

    func testEmptyObjectDecodes() throws {
        let snapshot = try decode(Snapshot.self, "{}")
        XCTAssertEqual(snapshot, .empty)
    }

    func testRoundTripPreservesEveryField() throws {
        var snapshot = Snapshot.empty
        snapshot.mine = Fixtures.status("💼", "working")
        snapshot.theirs = Fixtures.status(at: Fixtures.date(-60), nudges: 3)
        snapshot.isPaired = true
        snapshot.lastSyncedAt = Fixtures.t0
        snapshot.lastSeenPartnerNudgeCount = 3
        snapshot.lastNudgeSentAt = Fixtures.date(-5)
        snapshot.lastNudgeFailedAt = Fixtures.date(-4)
        snapshot.myStatusPublished = false
        snapshot.latestPartnerMoment = Fixtures.moment("v1", kind: .voice)
        snapshot.latestOwnMoment = Fixtures.moment("o1", fromMe: true)
        snapshot.latestPartnerVisualMoment = nil
        snapshot.notifiedMomentIDs = ["v1"]
        snapshot.lastNotifiedMomentID = "v1"
        snapshot.unheardVoiceMemoCount = 1
        snapshot.lastCelebratedAt = Fixtures.date(-3600)
        snapshot.lastAnnouncedPartnerStatusAt = Fixtures.date(-60)
        snapshot.receiptsDirty = true
        snapshot.partnerStatusSeen = StatusSeen(statusUpdatedAt: Fixtures.date(-60), seenAt: Fixtures.t0)
        snapshot.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: Fixtures.date(1))

        let data = try JSONEncoder.shared.encode(snapshot)
        let decoded = try JSONDecoder.shared.decode(Snapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.latestPartnerVisualMoment,
                     "nil visual moment must survive as an explicit null, not fall back")
    }

    func testAnnouncedWatermarkIsBoundedAndSticky() {
        var snapshot = Snapshot.empty
        for index in 0..<12 { snapshot.recordAnnounced("m\(index)") }
        XCTAssertEqual(snapshot.notifiedMomentIDs.count, 8)
        XCTAssertEqual(snapshot.lastNotifiedMomentID, "m11")
        XCTAssertTrue(snapshot.hasAnnounced("m11"))
        XCTAssertTrue(snapshot.hasAnnounced("m4"))
        XCTAssertFalse(snapshot.hasAnnounced("m3"))

        snapshot.recordAnnounced("m11")
        XCTAssertEqual(snapshot.notifiedMomentIDs.count, 8, "re-announcing must not duplicate")
        XCTAssertEqual(snapshot.notifiedMomentIDs.first, "m11")
    }

    func testStatusReceiptCountsOnlyForCurrentStatus() {
        var snapshot = Snapshot.empty
        snapshot.mine = Fixtures.status("💼", "working", at: Fixtures.t0)
        snapshot.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: Fixtures.date(30))
        XCTAssertEqual(snapshot.myStatusSeenAt, Fixtures.date(30))

        snapshot.mine = Fixtures.status("🍜", "ramen night", at: Fixtures.date(60))
        XCTAssertNil(snapshot.myStatusSeenAt, "a new status starts unseen again")
    }

    func testPendingCelebrationPlaysOnce() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status("🎉", "happy anniversary", at: Fixtures.t0, celebration: true)
        XCTAssertNotNil(snapshot.pendingCelebration)

        snapshot.lastCelebratedAt = Fixtures.t0
        XCTAssertNil(snapshot.pendingCelebration)

        snapshot.theirs = Fixtures.status("🎉", "again!", at: Fixtures.date(10), celebration: true)
        XCTAssertNotNil(snapshot.pendingCelebration, "a newer celebration plays again")

        snapshot.theirs = Fixtures.status("💼", "working", at: Fixtures.date(20))
        XCTAssertNil(snapshot.pendingCelebration)
    }

    func testDerivedHelpers() {
        var snapshot = Snapshot.empty
        XCTAssertEqual(snapshot.partnerDisplayName, "Partner")
        XCTAssertNil(snapshot.latestMoment)

        snapshot.theirs = Fixtures.status()
        snapshot.latestPartnerMoment = Fixtures.moment("p", at: Fixtures.date(-10))
        snapshot.latestOwnMoment = Fixtures.moment("o", at: Fixtures.t0, fromMe: true)
        XCTAssertEqual(snapshot.partnerDisplayName, "Sam")
        XCTAssertEqual(snapshot.latestMoment?.id, "o")
    }
}
