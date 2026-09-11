import XCTest

/// The watermark claims behind every notification (CLAUDE.md invariant 10):
/// each event is announced once across the app, widget and service extension.
final class AnnouncementPolicyTests: XCTestCase {
    private func result(nudges: Int? = nil, moments: [Moment] = []) -> RefreshResult {
        RefreshResult(partnerStatus: nudges.map { Fixtures.status(nudges: $0) },
                      newPartnerMoments: moments)
    }

    // MARK: Refresh claims

    func testFirstSightOfPartnerAdoptsNudgeCountSilently() {
        var snapshot = Snapshot.empty
        let claims = AnnouncementPolicy.claim(result(nudges: 3), previousStatus: nil, in: &snapshot)
        XCTAssertFalse(claims.nudge)
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 3, "history, not a fresh tap — but still the watermark")
    }

    func testNudgeCountIncreaseAnnouncesExactlyOnce() {
        var snapshot = Snapshot.empty
        snapshot.lastSeenPartnerNudgeCount = 2
        let previous = Fixtures.status(nudges: 2)
        XCTAssertTrue(AnnouncementPolicy.claim(result(nudges: 3), previousStatus: previous, in: &snapshot).nudge)
        XCTAssertFalse(AnnouncementPolicy.claim(result(nudges: 3), previousStatus: previous, in: &snapshot).nudge,
                       "a second process seeing the same delta must not announce again")
        XCTAssertFalse(AnnouncementPolicy.claim(result(nudges: 1), previousStatus: previous, in: &snapshot).nudge,
                       "the watermark moves with max(), never down")
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 3)
    }

    func testOnlyNewestMomentIsAnnouncedAndOnlyOnce() {
        var snapshot = Snapshot.empty
        let older = Fixtures.moment("m1", at: Fixtures.date(10))
        let newer = Fixtures.moment("m2", at: Fixtures.date(20))
        let first = AnnouncementPolicy.claim(result(moments: [older, newer]), previousStatus: nil, in: &snapshot)
        XCTAssertEqual(first.moment?.id, "m2")
        XCTAssertTrue(snapshot.hasAnnounced("m2"))
        XCTAssertFalse(snapshot.hasAnnounced("m1"), "the older one was skipped, not claimed")
        let again = AnnouncementPolicy.claim(result(moments: [older, newer]), previousStatus: nil, in: &snapshot)
        XCTAssertNil(again.moment)
    }

    func testChangedReflectsStatusOrMoments() {
        let status = Fixtures.status()
        XCTAssertFalse(AnnouncementPolicy.changed(RefreshResult(partnerStatus: status), previousStatus: status))
        XCTAssertTrue(AnnouncementPolicy.changed(RefreshResult(partnerStatus: nil), previousStatus: status))
        XCTAssertTrue(AnnouncementPolicy.changed(result(moments: [Fixtures.moment("m1")]), previousStatus: nil))
    }

    // MARK: Push banner claims (notification service)

    func testStatusBannerClaimsOnlyNewerThanWatermark() {
        var snapshot = Snapshot.empty
        let status = Fixtures.status(at: Fixtures.date(100))
        XCTAssertTrue(AnnouncementPolicy.claimStatusBanner(for: status, in: &snapshot))
        XCTAssertEqual(snapshot.lastAnnouncedPartnerStatusAt, Fixtures.date(100))
        XCTAssertFalse(AnnouncementPolicy.claimStatusBanner(for: status, in: &snapshot), "concurrent push instance")
        XCTAssertFalse(AnnouncementPolicy.claimStatusBanner(for: Fixtures.status(at: Fixtures.date(50)), in: &snapshot))
        XCTAssertTrue(AnnouncementPolicy.claimStatusBanner(for: Fixtures.status(at: Fixtures.date(101)), in: &snapshot))
    }

    func testMomentBannerPrefersUnannouncedFromDeltaThenIndex() {
        var snapshot = Snapshot.empty
        let indexed = Fixtures.moment("i1", at: Fixtures.date(5))
        let mine = Fixtures.moment("own", at: Fixtures.date(50), fromMe: true)
        let a = Fixtures.moment("a", at: Fixtures.date(10))
        let b = Fixtures.moment("b", at: Fixtures.date(20))

        // Newest un-announced from the delta, regardless of the delta's order.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [a, b], index: [mine, indexed], in: &snapshot)?.id, "b")
        // Same delta again (the widget consumed it first): falls to the next un-announced.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [a, b], index: [mine, indexed], in: &snapshot)?.id, "a")
        // Delta empty: the index's newest un-announced partner moment, never an own send.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [], index: [mine, indexed], in: &snapshot)?.id, "i1")
        // Everything announced: still names the newest so the banner isn't blank.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [], index: [mine, indexed], in: &snapshot)?.id, "i1")
        XCTAssertNil(AnnouncementPolicy.claimMomentBanner(delta: [], index: [mine], in: &snapshot))
    }
}
