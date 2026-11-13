import CloudKit
import XCTest

/// The widget's next-refresh schedule: hourly when caught up, soon while a
/// locked phone's pushes sit unread, backing off the longer they wait.
final class WidgetReloadPolicyTests: XCTestCase {
    private let now = Fixtures.date(24 * 60 * 60)

    private func delay(heldFor waited: TimeInterval?, incomplete: Bool = false) -> TimeInterval {
        let heldSince = waited.map { now.addingTimeInterval(-$0) }
        return WidgetReloadPolicy.nextReload(heldSince: heldSince, incomplete: incomplete, now: now)
            .timeIntervalSince(now)
    }

    func testCaughtUpIsHourly() {
        XCTAssertEqual(delay(heldFor: nil), WidgetReloadPolicy.settled)
    }

    func testIncompleteBatchComesBackSoon() {
        XCTAssertEqual(delay(heldFor: nil, incomplete: true), 5 * 60)
    }

    func testHeldRecordsBackOff() {
        XCTAssertEqual(delay(heldFor: 0), 10 * 60)
        XCTAssertEqual(delay(heldFor: 29 * 60), 10 * 60)
        XCTAssertEqual(delay(heldFor: 30 * 60), 20 * 60)
        XCTAssertEqual(delay(heldFor: 2 * 60 * 60), WidgetReloadPolicy.settled,
                       "past two hours the retries stop costing more than the backstop")
        XCTAssertEqual(delay(heldFor: 3 * 24 * 60 * 60), WidgetReloadPolicy.settled)
    }

    /// A phone locked for eight hours after a push stays well inside WidgetKit's
    /// daily reload budget (roughly 40–70 per widget).
    func testOvernightLockStaysInBudget() {
        let start = now
        var clock = start
        var reloads = 0
        while clock.timeIntervalSince(start) < 8 * 60 * 60 {
            clock = WidgetReloadPolicy.nextReload(heldSince: start, incomplete: false, now: clock)
            reloads += 1
        }
        XCTAssertLessThanOrEqual(reloads, 14)
    }

    /// Before first unlock nothing can be read and the widget draws from nothing:
    /// back within 15 minutes of the unlock, not an hour — offline or not.
    func testALockedRunComesBackSoon() {
        XCTAssertEqual(WidgetReloadPolicy.nextReload(heldSince: nil, incomplete: false, locked: true, now: now)
                        .timeIntervalSince(now), WidgetReloadPolicy.whileLocked)
        XCTAssertEqual(WidgetReloadPolicy.nextReload(heldSince: nil, incomplete: false, offline: true,
                                                     locked: true, now: now).timeIntervalSince(now),
                       WidgetReloadPolicy.whileLocked)
        XCTAssertLessThan(WidgetReloadPolicy.whileLocked, WidgetReloadPolicy.settled)
    }

    func testRecentFetchIsShared() {
        XCTAssertTrue(WidgetReloadPolicy.shouldFetch(lastSyncedAt: nil, now: now))
        XCTAssertFalse(WidgetReloadPolicy.shouldFetch(lastSyncedAt: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(WidgetReloadPolicy.shouldFetch(lastSyncedAt: now.addingTimeInterval(-61), now: now))
        XCTAssertTrue(WidgetReloadPolicy.shouldFetch(lastSyncedAt: now.addingTimeInterval(3600), now: now),
                      "a future stamp is a skewed clock, not a fresh fetch")
    }

    func testHeldBeatsIncomplete() {
        XCTAssertEqual(delay(heldFor: 60 * 60, incomplete: true), 20 * 60)
    }

    /// Retrying a held record every 10 minutes can't fetch it offline; the
    /// budget is kept for when it can. Reconnecting is the held push's job.
    func testOfflineBacksOffToHourlyEvenWhenHeld() {
        let held = WidgetReloadPolicy.nextReload(heldSince: now, incomplete: false, offline: true, now: now)
        XCTAssertEqual(held, now.addingTimeInterval(WidgetReloadPolicy.settled))
        XCTAssertEqual(WidgetReloadPolicy.nextReload(heldSince: now, incomplete: false, offline: false, now: now),
                       now.addingTimeInterval(10 * 60), "online, a held record still retries soon")
        let plan = TimelinePlan(lastNudgeSentAt: nil, lastNudgeFailedAt: nil, heldSince: now,
                                incomplete: false, offline: true, now: now)
        XCTAssertEqual(plan.nextReload, held)
    }

    /// An Apple sign-in outage reads like no route: retrying soon can't get
    /// past it, so the widget waits hourly instead of spending its budget.
    func testSignInFailuresWaitLikeOffline() {
        XCTAssertTrue(WidgetReloadPolicy.waitsQuietly(after: CKError(.networkUnavailable)))
        XCTAssertTrue(WidgetReloadPolicy.waitsQuietly(after: CKError(.accountTemporarilyUnavailable)))
        XCTAssertTrue(WidgetReloadPolicy.waitsQuietly(after: CKError(.notAuthenticated)))
        XCTAssertTrue(WidgetReloadPolicy.waitsQuietly(after: SyncError.iCloudUnavailable(.noAccount)))
        XCTAssertFalse(WidgetReloadPolicy.waitsQuietly(after: CKError(.serverResponseLost)))
        XCTAssertFalse(WidgetReloadPolicy.waitsQuietly(after: CancellationError()))
    }

    /// Opening the app redraws without fetching; the outage it hit must stay visible.
    func testAWidgetRunKeepsTheLastFetchThroughRedraws() {
        let failed = SharedStore.WidgetRun.recorded(after: nil, at: now, outcome: .unreachable,
                                                    detail: "no auth token", nextReload: now.addingTimeInterval(3600))
        XCTAssertEqual(failed.lastFetch?.outcome, .unreachable)
        let redrawn = SharedStore.WidgetRun.recorded(after: failed, at: now.addingTimeInterval(60), outcome: .skipped,
                                                     detail: nil, nextReload: now.addingTimeInterval(3600))
        XCTAssertEqual(redrawn.outcome, .skipped)
        XCTAssertEqual(redrawn.lastFetch, failed.lastFetch)
        let fetched = SharedStore.WidgetRun.recorded(after: redrawn, at: now.addingTimeInterval(120), outcome: .fetched,
                                                     detail: nil, nextReload: now.addingTimeInterval(3600))
        XCTAssertEqual(fetched.lastFetch?.outcome, .fetched)
    }

    /// A run stored before `lastFetch` existed still reads; the summary names the old attempt.
    func testAWidgetRunReadsOldDataAndSaysWhatItLastTried() throws {
        let legacy = #"{"at":"2026-11-11T09:00:00Z","outcome":"skipped","nextReload":"2026-11-11T10:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(SharedStore.WidgetRun.self, from: Data(legacy.utf8))
        XCTAssertNil(old.lastFetch)
        let failed = SharedStore.WidgetRun.recorded(after: nil, at: now, outcome: .unreachable,
                                                    detail: "no auth token", nextReload: now)
        let redrawn = SharedStore.WidgetRun.recorded(after: failed, at: now.addingTimeInterval(60),
                                                     outcome: .skipped, detail: nil, nextReload: now)
        XCTAssertTrue(redrawn.summary.contains("last fetch"))
        XCTAssertTrue(redrawn.summary.contains("no auth token"))
        XCTAssertFalse(failed.summary.contains("last fetch"), "its own attempt isn't repeated")
    }
}
