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

    func testOnlyNewestMomentIsAnnouncedButTheWholeBurstIsClaimed() {
        var snapshot = Snapshot.empty
        let older = Fixtures.moment("m1", at: Fixtures.date(10))
        let newer = Fixtures.moment("m2", at: Fixtures.date(20))
        let first = AnnouncementPolicy.claim(result(moments: [older, newer]), previousStatus: nil, in: &snapshot)
        XCTAssertEqual(first.moment?.id, "m2")
        XCTAssertTrue(snapshot.hasAnnounced("m2"))
        XCTAssertTrue(snapshot.hasAnnounced("m1"), "claimed too, or a later push banner would call it new")
        XCTAssertEqual(snapshot.lastAnnouncedMomentSentAt, Fixtures.date(20))
        let again = AnnouncementPolicy.claim(result(moments: [older, newer]), previousStatus: nil, in: &snapshot)
        XCTAssertNil(again.moment)
    }

    /// A re-fetched history (reinstall, token expiry) fills the index with
    /// hundreds of never-announced moments; the banner fallback must not pick one.
    func testMomentBannerIndexFallbackNeverReachesBehindTheFloor() {
        var snapshot = Snapshot.empty
        snapshot.lastAnnouncedMomentSentAt = Fixtures.date(100)
        let old = Fixtures.moment("old", at: Fixtures.date(50))
        let fresh = Fixtures.moment("fresh", at: Fixtures.date(150))
        XCTAssertNil(AnnouncementPolicy.claimMomentBanner(delta: [], index: [old], in: &snapshot))
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [], index: [fresh, old], in: &snapshot)?.id, "fresh")
        XCTAssertEqual(snapshot.lastAnnouncedMomentSentAt, Fixtures.date(150))
        // The delta is always trusted: it is this refresh's own news.
        snapshot = Snapshot.empty
        snapshot.lastAnnouncedMomentSentAt = Fixtures.date(100)
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [old], index: [], in: &snapshot)?.id, "old")
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
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: status, in: &snapshot), .update)
        XCTAssertEqual(snapshot.lastAnnouncedPartnerStatusAt, Fixtures.date(100))
        XCTAssertEqual(snapshot.lastAnnouncedPartnerStatus, status)
        XCTAssertNil(AnnouncementPolicy.claimStatusBanner(for: status, in: &snapshot), "concurrent push instance")
        XCTAssertNil(AnnouncementPolicy.claimStatusBanner(for: Fixtures.status(at: Fixtures.date(50)), in: &snapshot))
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: Fixtures.status(at: Fixtures.date(101)), in: &snapshot), .update)
    }

    /// Judged against the last *announced* status, not a pre-refresh snapshot:
    /// when the widget consumed the delta first, that snapshot is already current.
    func testStatusBannerTellsARenameFromANewStatus() {
        var snapshot = Snapshot.empty
        _ = AnnouncementPolicy.claimStatusBanner(for: Fixtures.status("🥰", "missing you", at: Fixtures.date(100)), in: &snapshot)
        // The widget already folded the renamed status into `theirs`.
        var renamed = Fixtures.status("🥰", "missing you", at: Fixtures.date(200))
        renamed.displayName = "Samantha"
        snapshot.theirs = renamed
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: renamed, in: &snapshot),
                       .rename(previousName: "Sam"))
        // New words with the new name: a status, not another rename.
        var next = Fixtures.status("☕", "coffee", at: Fixtures.date(300))
        next.displayName = "Samantha"
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: next, in: &snapshot), .update)
    }

    func testLegacySnapshotWithoutAnnouncedStatusTreatsFirstPushAsUpdate() {
        var snapshot = Snapshot.empty
        snapshot.lastAnnouncedPartnerStatusAt = Fixtures.date(50)
        var renamed = Fixtures.status(at: Fixtures.date(100))
        renamed.displayName = "Samantha"
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: renamed, in: &snapshot), .update)
    }

    func testNudgeBannerClaimsPastWatermarkOnly() {
        var snapshot = Snapshot.empty
        snapshot.lastSeenPartnerNudgeCount = 2
        XCTAssertFalse(AnnouncementPolicy.claimNudgeBanner(count: 2, in: &snapshot), "own device's nudge, or already announced")
        XCTAssertTrue(AnnouncementPolicy.claimNudgeBanner(count: 3, in: &snapshot))
        XCTAssertFalse(AnnouncementPolicy.claimNudgeBanner(count: 3, in: &snapshot), "concurrent instance")
        XCTAssertFalse(AnnouncementPolicy.claimNudgeBanner(count: 1, in: &snapshot))
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 3)
    }

    func testMomentBannerPrefersUnannouncedFromDeltaThenIndex() {
        var snapshot = Snapshot.empty
        // Newer than anything the delta announces — an indexed moment *older*
        // than the last announced one is history, not news (see the floor test).
        let indexed = Fixtures.moment("i1", at: Fixtures.date(30))
        let mine = Fixtures.moment("own", at: Fixtures.date(50), fromMe: true)
        let a = Fixtures.moment("a", at: Fixtures.date(10))
        let b = Fixtures.moment("b", at: Fixtures.date(20))

        // Newest un-announced from the delta, regardless of the delta's order.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [a, b], index: [mine, indexed], in: &snapshot)?.id, "b")
        // Same delta again (the widget consumed it first): falls to the next un-announced.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [a, b], index: [mine, indexed], in: &snapshot)?.id, "a")
        // Delta empty: the index's newest un-announced partner moment, never an own send.
        XCTAssertEqual(AnnouncementPolicy.claimMomentBanner(delta: [], index: [mine, indexed], in: &snapshot)?.id, "i1")
        // Everything announced: nothing — a push about an own send from another
        // device must not re-describe an old partner moment as new.
        XCTAssertNil(AnnouncementPolicy.claimMomentBanner(delta: [], index: [mine, indexed], in: &snapshot))
        XCTAssertNil(AnnouncementPolicy.claimMomentBanner(delta: [], index: [mine], in: &snapshot))
    }
}
