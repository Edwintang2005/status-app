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

    func testOnlyNewestMomentIsAnnouncedButTheWholeBurstIsTaken() {
        var snapshot = Snapshot.empty
        snapshot.owe([Fixtures.moment("m1", at: Fixtures.date(10)), Fixtures.moment("m2", at: Fixtures.date(20))])
        let first = AnnouncementPolicy.claim(result(), previousStatus: nil, in: &snapshot)
        XCTAssertEqual(first.moment?.id, "m2")
        XCTAssertEqual(snapshot.lastNotifiedMomentID, "m2")
        XCTAssertTrue(snapshot.owedMoments.isEmpty, "m1 taken too, or a later push banner would call it new")
        XCTAssertNil(AnnouncementPolicy.claim(result(), previousStatus: nil, in: &snapshot).moment,
                     "a second process seeing the same delta must not announce again")
    }

    /// A photo another pass filed (a heart's push carried it; the widget fetched
    /// it and its own push never came) is still owed: the app's next refresh
    /// announces it, once.
    func testTheAppCatchesUpMomentsAnotherPassFiled() {
        var snapshot = Snapshot.empty
        snapshot.owe([Fixtures.moment("filed", at: Fixtures.date(150))])
        XCTAssertEqual(AnnouncementPolicy.claim(result(), previousStatus: nil, in: &snapshot).moment?.id, "filed")
        XCTAssertNil(AnnouncementPolicy.claim(result(), previousStatus: nil, in: &snapshot).moment, "announced once")
    }

    /// Nothing owed, nothing said: a re-fetched history (reinstall, token
    /// expiry) is never owed, so no banner can describe an old moment as new.
    func testNothingOwedAnnouncesNothing() {
        var snapshot = Snapshot.empty
        XCTAssertNil(AnnouncementPolicy.takeOwedMoments(in: &snapshot))
        XCTAssertNil(snapshot.lastNotifiedMomentID)
    }

    /// The newest to *arrive*, not the newest `sentAt`: that's the partner's clock,
    /// and a phone hours ahead must not make its moment outrank later ones.
    func testTheBannerIsTheLastToArriveWhateverItsClock() {
        var snapshot = Snapshot.empty
        snapshot.owe([Fixtures.moment("skewed", at: Date().addingTimeInterval(3 * 86_400))])
        snapshot.owe([Fixtures.moment("later", at: Date())])
        XCTAssertEqual(AnnouncementPolicy.takeOwedMoments(in: &snapshot)?.id, "later")
    }

    /// Filed once, words kept current, settled when there's nothing left to say, bounded.
    func testTheOwedListFilesOnceRefreshesWordsAndSettles() {
        var snapshot = Snapshot.empty
        var moment = Fixtures.moment("m1")
        snapshot.owe([moment])
        snapshot.owe([moment])
        XCTAssertEqual(snapshot.owedMoments.count, 1, "a re-delivery isn't a second owing")

        moment.caption = "edited before anyone announced it"
        snapshot.owe([], refreshing: [moment])
        XCTAssertEqual(snapshot.owedMoments.first?.caption, "edited before anyone announced it")
        snapshot.owe([], refreshing: [Fixtures.moment("other")])
        XCTAssertEqual(snapshot.owedMoments.map(\.id), ["m1"], "a delivered copy isn't owed by itself")

        snapshot.settleOwed(["m1"])
        XCTAssertTrue(snapshot.owedMoments.isEmpty)

        snapshot.owe((0..<(Snapshot.owedMomentLimit + 5)).map { Fixtures.moment("b\($0)") })
        XCTAssertEqual(snapshot.owedMoments.count, Snapshot.owedMomentLimit)
        XCTAssertEqual(snapshot.owedMoments.last?.id, "b\(Snapshot.owedMomentLimit + 4)", "the newest kept")
    }

    /// The fold is where moments become owed: news, refreshed words, deletions.
    func testTheFoldOwesNewsAndSettlesDeletions() {
        var snapshot = Snapshot.empty
        snapshot.owe([Fixtures.moment("gone")])
        var fold = RefreshDelta()
        fold.owedMoments = [Fixtures.moment("new")]
        fold.settledMomentIDs = ["gone"]
        fold.readUpTo = Fixtures.date(500)
        fold.fold(into: &snapshot)
        XCTAssertEqual(snapshot.owedMoments.map(\.id), ["new"])
        XCTAssertEqual(snapshot.newsAfter, Fixtures.date(500))

        var older = RefreshDelta()
        older.readUpTo = Fixtures.date(100)
        older.fold(into: &snapshot)
        XCTAssertEqual(snapshot.newsAfter, Fixtures.date(500), "the mark only rises")

        // …unless it's over a day ahead: a seed from a fast clock is stale, not kept.
        let now = Date()
        snapshot.newsAfter = now.addingTimeInterval(3 * AppConfig.clockSkewAllowance)
        var read = RefreshDelta()
        read.readUpTo = now.addingTimeInterval(-60)
        read.fold(into: &snapshot, now: now)
        XCTAssertEqual(snapshot.newsAfter, now.addingTimeInterval(-60))
    }

    /// A fresh start committed between a delta's parse and its fold: what it cleared is owed nothing.
    func testAMomentClearedByAFreshStartIsOwedNothing() {
        var snapshot = Snapshot.empty
        snapshot.freshStart.clearedBefore = Fixtures.date(1_000)
        var fold = RefreshDelta()
        fold.owedMoments = [Fixtures.moment("cleared"), Fixtures.moment("kept")]
        fold.owedCreatedAt = ["cleared": Fixtures.date(500), "kept": Fixtures.date(2_000)]
        fold.fold(into: &snapshot)
        XCTAssertEqual(snapshot.owedMoments.map(\.id), ["kept"])
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

    /// Rapid pushes run as concurrent service instances: only one gets the moment.
    func testConcurrentPushesNeverTakeTheSameMoment() {
        var snapshot = Snapshot.empty
        snapshot.owe([Fixtures.moment("a")])
        XCTAssertEqual(AnnouncementPolicy.takeOwedMoments(in: &snapshot)?.id, "a")
        XCTAssertNil(AnnouncementPolicy.takeOwedMoments(in: &snapshot))
    }

    // MARK: Locked-phone wording (invariant 10's unreadable exception)

    func testHeldMomentBodyNamesTheKindOnlyWhenTheyAgree() {
        XCTAssertNil(AnnouncementPolicy.heldMomentBody(kinds: []), "nothing of the partner's: generic words stay")
        XCTAssertEqual(AnnouncementPolicy.heldMomentBody(kinds: [.drawing]), Moment.Kind.drawing.arrivalSummary)
        XCTAssertEqual(AnnouncementPolicy.heldMomentBody(kinds: [.photo, .photo]), Moment.Kind.photo.arrivalSummary)
        let mixed = AnnouncementPolicy.heldMomentBody(kinds: [.photo, .voice])
        XCTAssertNotNil(mixed)
        XCTAssertNotEqual(mixed, Moment.Kind.photo.arrivalSummary, "can't tell which one this push was for")
        XCTAssertNotEqual(mixed, Moment.Kind.voice.arrivalSummary)
    }

    // MARK: Nudge interruption

    func testNudgeBreaksThroughFocusOncePerInterval() {
        var snapshot = Snapshot.empty
        let now = Fixtures.t0
        let first = AnnouncementPolicy.nudgeInterruption(sentAt: now, in: &snapshot, now: now)
        XCTAssertEqual(first, .init(stale: false, breaksThroughFocus: true))
        let repeatTap = AnnouncementPolicy.nudgeInterruption(sentAt: now.addingTimeInterval(20), in: &snapshot,
                                                             now: now.addingTimeInterval(20))
        XCTAssertEqual(repeatTap, .init(stale: false, breaksThroughFocus: false), "a burst can't keep piercing Focus")
        let later = now.addingTimeInterval(AppConfig.nudgeBreakthroughInterval + 1)
        XCTAssertTrue(AnnouncementPolicy.nudgeInterruption(sentAt: later, in: &snapshot, now: later).breaksThroughFocus)
    }

    func testLateNudgeIsStaleAndQuiet() {
        var snapshot = Snapshot.empty
        let now = Fixtures.t0
        let late = AnnouncementPolicy.nudgeInterruption(sentAt: now.addingTimeInterval(-3600), in: &snapshot, now: now)
        XCTAssertEqual(late, .init(stale: true, breaksThroughFocus: false))
        XCTAssertNil(snapshot.lastBreakthroughNudgeAt, "a stale one doesn't use up the breakthrough")
    }

    func testFutureWatermarkDoesNotSilenceStatuses() {
        var snapshot = Snapshot.empty
        snapshot.lastAnnouncedPartnerStatusAt = Date().addingTimeInterval(3 * 86_400)
        let status = Fixtures.status("☕️", "coffee?", at: Date().addingTimeInterval(-60))
        XCTAssertEqual(AnnouncementPolicy.claimStatusBanner(for: status, in: &snapshot), .update)
    }
}
