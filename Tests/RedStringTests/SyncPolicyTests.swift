import XCTest

/// Small pure rules the sync layer delegates to: the zone-gone verdict
/// (invariant 8), the refresh gate, and the `Snapshot` flag rules behind the
/// outbox (invariants 13 and 16).
final class SyncPolicyTests: XCTestCase {
    // MARK: ZoneGonePolicy

    func testZoneGoneNeedsASecondSightingAfterTheWindow() {
        let window = AppConfig.zoneGoneConfirmation
        XCTAssertEqual(ZoneGonePolicy.decide(firstSeen: nil, now: Fixtures.t0), .firstSighting)
        XCTAssertEqual(ZoneGonePolicy.decide(firstSeen: Fixtures.t0, now: Fixtures.date(window - 1)), .waiting)
        XCTAssertEqual(ZoneGonePolicy.decide(firstSeen: Fixtures.t0, now: Fixtures.date(window)), .gone)
    }

    func testAFutureSightingIsRestampedNotHeldForever() {
        XCTAssertEqual(ZoneGonePolicy.decide(firstSeen: Fixtures.date(3_600), now: Fixtures.t0), .firstSighting)
    }

    // MARK: RefreshGate

    func testGateNotesARequestMidFetchAndRunsItOnce() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.begin(), "one fetch at a time")
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.takeRequest(), "the fetch runs again")
        XCTAssertFalse(gate.takeRequest(), "once, however many asked")
        gate.end()
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.begin())
    }

    func testDiagnosticsResyncIsNobodysRequest() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(noteIfBusy: false))
        XCTAssertFalse(gate.takeRequest())
    }

    // MARK: Snapshot flag rules

    func testStatusIsMarkedPublishedOnlyWhileStillCurrent() {
        var snapshot = Snapshot.empty
        snapshot.myStatusPublished = false
        let sent = Fixtures.status(at: Fixtures.t0)
        snapshot.mine = Fixtures.status("☕️", "coffee?", at: Fixtures.date(10))
        snapshot.markStatusPublished(sent)
        XCTAssertFalse(snapshot.myStatusPublished, "a late publish must not mark a newer edit delivered")
        snapshot.mine = sent
        snapshot.markStatusPublished(sent)
        XCTAssertTrue(snapshot.myStatusPublished)
    }

    func testAnniversaryFlagsFollowTheCurrentValue() {
        var snapshot = Snapshot.empty
        snapshot.anniversaryRequestPublished = false
        snapshot.anniversaryRequestedAt = Fixtures.date(5)
        snapshot.markAnniversaryRequestPublished(Fixtures.t0)
        XCTAssertFalse(snapshot.anniversaryRequestPublished)
        snapshot.markAnniversaryRequestPublished(Fixtures.date(5))
        XCTAssertTrue(snapshot.anniversaryRequestPublished)

        snapshot.anniversary = Anniversary(startsAt: Fixtures.date(86_400), timeZoneID: "UTC")
        snapshot.anniversaryPublished = false
        snapshot.markAnniversaryPublished(Anniversary(startsAt: Fixtures.t0, timeZoneID: "UTC"))
        XCTAssertFalse(snapshot.anniversaryPublished, "a late publish of an older date")

        snapshot.anniversary = nil
        snapshot.markAnniversaryPublished(nil)
        XCTAssertTrue(snapshot.anniversaryPublished, "a removal is a value too")
    }

    func testReceiptsDirtyIsClaimedOnce() {
        var snapshot = Snapshot.empty
        XCTAssertFalse(snapshot.claimReceiptsDirty())
        snapshot.receiptsDirty = true
        XCTAssertTrue(snapshot.claimReceiptsDirty())
        XCTAssertFalse(snapshot.receiptsDirty)
        XCTAssertFalse(snapshot.claimReceiptsDirty())
    }

    func testStatusReceiptOnlyMovesForward() {
        var snapshot = Snapshot.empty
        XCTAssertFalse(snapshot.stampPartnerStatusSeen(nil, at: Fixtures.t0), "nothing to have seen")
        let shown = Fixtures.status(at: Fixtures.date(100))
        XCTAssertTrue(snapshot.stampPartnerStatusSeen(shown, at: Fixtures.date(120)))
        XCTAssertEqual(snapshot.partnerStatusSeen?.statusUpdatedAt, Fixtures.date(100))
        XCTAssertTrue(snapshot.receiptsDirty)

        snapshot.receiptsDirty = false
        XCTAssertFalse(snapshot.stampPartnerStatusSeen(shown, at: Fixtures.date(200)), "already seen")
        XCTAssertFalse(snapshot.stampPartnerStatusSeen(Fixtures.status(at: Fixtures.date(50)), at: Fixtures.date(300)),
                       "a re-delivered older status")
        XCTAssertEqual(snapshot.partnerStatusSeen?.seenAt, Fixtures.date(120))
        XCTAssertFalse(snapshot.receiptsDirty)
    }

    func testAPlaceholderStatusIsNeverStamped() {
        var fresh = Snapshot.empty
        XCTAssertFalse(fresh.stampPartnerStatusSeen(Fixtures.status(at: .distantPast), at: Fixtures.t0),
                       "a placeholder was never on screen")
        XCTAssertNil(fresh.partnerStatusSeen)
    }

    /// The receipt names the status on screen, not a newer one another process
    /// filed into the store that the screen hasn't shown yet.
    func testStatusReceiptStampsWhatWasShown() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status("☕️", "coffee?", at: Fixtures.date(500))
        XCTAssertTrue(snapshot.stampPartnerStatusSeen(Fixtures.status(at: Fixtures.date(100)), at: Fixtures.date(510)))
        XCTAssertEqual(snapshot.partnerStatusSeen?.statusUpdatedAt, Fixtures.date(100))
    }

    func testAutomaticRetryWaitsAfterAFullICloud() {
        let interval = AppConfig.storageFullRetryInterval
        XCTAssertTrue(Outbox.automaticRetryAllowed(storageFullAt: nil, now: Fixtures.t0))
        XCTAssertFalse(Outbox.automaticRetryAllowed(storageFullAt: Fixtures.t0, now: Fixtures.date(interval - 1)))
        XCTAssertTrue(Outbox.automaticRetryAllowed(storageFullAt: Fixtures.t0, now: Fixtures.date(interval)))
        XCTAssertTrue(Outbox.automaticRetryAllowed(storageFullAt: Fixtures.date(60), now: Fixtures.t0),
                      "a stamp ahead of the clock doesn't hold retries off")
    }

    func testSeenMapCoversOnlyThePartnersSeenMoments() {
        var legacy = Fixtures.moment("legacy", seen: true)
        legacy.seenAt = nil
        XCTAssertEqual(Outbox.seenMap(from: [legacy])["legacy"], .distantPast, "seen before timestamps existed")

        let history = [
            Fixtures.moment("a", seen: true),
            Fixtures.moment("b", seen: false),
            Fixtures.moment("c", fromMe: true),
            Fixtures.moment("d", seen: true),
        ]
        let map = Outbox.seenMap(from: history, limit: 1)
        XCTAssertEqual(Array(map.keys), ["a"], "newest first, capped")
        XCTAssertEqual(Set(Outbox.seenMap(from: history).keys), ["a", "d"])
    }
}
