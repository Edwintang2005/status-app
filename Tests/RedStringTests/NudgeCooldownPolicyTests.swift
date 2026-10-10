import XCTest

/// The lock-screen heart giving up at its deadline: only its own unlanded claim
/// is released (invariant 7).
final class NudgeCooldownPolicyTests: XCTestCase {
    private let started = Fixtures.t0
    private let now = Fixtures.date(8)

    private func snapshot(claim: Date?, landedAt: Date? = nil) -> Snapshot {
        var snapshot = Snapshot.empty
        var mine = Fixtures.status()
        mine.lastNudgeAt = landedAt
        snapshot.mine = mine
        snapshot.lastNudgeSentAt = claim
        return snapshot
    }

    func testADeadlineBeforeTheSaveReleasesTheClaim() {
        for claim in [started, Fixtures.date(1)] {
            var snapshot = snapshot(claim: claim)
            XCTAssertTrue(NudgeCooldownPolicy.releaseAbandoned(startedAt: started, in: &snapshot, now: now))
            XCTAssertNil(snapshot.lastNudgeSentAt, "the next tap retries at once")
            XCTAssertEqual(snapshot.lastNudgeFailedAt, now, "the heart's only error channel")
        }
    }

    func testASaveThatLandedKeepsTheCooldown() {
        var snapshot = snapshot(claim: started, landedAt: started)
        XCTAssertFalse(NudgeCooldownPolicy.releaseAbandoned(startedAt: started, in: &snapshot, now: now))
        XCTAssertEqual(snapshot.lastNudgeSentAt, started)
        XCTAssertNil(snapshot.lastNudgeFailedAt)
    }

    func testAnotherProcesssClaimIsLeftStanding() {
        // Claimed after our cooldown ran out: the app's tap, maybe still sending.
        var newer = snapshot(claim: started.addingTimeInterval(AppConfig.nudgeCooldown + 2))
        XCTAssertFalse(NudgeCooldownPolicy.releaseAbandoned(startedAt: started, in: &newer, now: now))
        XCTAssertNotNil(newer.lastNudgeSentAt)
        XCTAssertNil(newer.lastNudgeFailedAt)

        // Standing from before we started: our tap was refused by the cooldown.
        var older = snapshot(claim: started.addingTimeInterval(-1))
        XCTAssertFalse(NudgeCooldownPolicy.releaseAbandoned(startedAt: started, in: &older, now: now))
        XCTAssertNotNil(older.lastNudgeSentAt)
    }

    func testNoClaimNoStamp() {
        var snapshot = snapshot(claim: nil)
        XCTAssertFalse(NudgeCooldownPolicy.releaseAbandoned(startedAt: started, in: &snapshot, now: now))
        XCTAssertNil(snapshot.lastNudgeFailedAt)
    }
}
