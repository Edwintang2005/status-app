import XCTest

/// The open app reuses another process's fetch only when it took the whole
/// delta, readable (`AppFetchPolicy`, `RefreshResult.isWholeDelta`).
final class AppFetchPolicyTests: XCTestCase {
    private let now = Fixtures.t0

    private func state(syncedAgo: TimeInterval? = 5) -> AppFetchPolicy.Foreground {
        AppFetchPolicy.Foreground(lastSyncedAt: syncedAgo.map { now.addingTimeInterval(-$0) },
                                  heldSince: nil, pushesArrive: true, hasChangeToken: true,
                                  lastPushID: "push-1", wholePushID: "push-1")
    }

    func testForegroundReusesARecentCompleteFetch() {
        XCTAssertFalse(AppFetchPolicy.fetchesOnForeground(state(), now: now))
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(state(syncedAgo: 30), now: now), "past the window")
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(state(syncedAgo: nil), now: now), "never synced")
    }

    func testForegroundFetchesWhileRecordsAreHeld() {
        var held = state()
        held.heldSince = now.addingTimeInterval(-60)
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(held, now: now))
    }

    func testAFutureSyncStampIsNoReason() {
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(state(syncedAgo: -3600), now: now))
    }

    /// A push whose service pass failed, timed out or took one batch: the app
    /// has no timer, so the foreground is what catches it.
    func testAnUnfinishedPushIsFetchedOnForeground() {
        var unfinished = state()
        unfinished.lastPushID = "push-2"
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(unfinished, now: now))
        var none = state()
        none.lastPushID = nil
        none.wholePushID = nil
        XCTAssertFalse(AppFetchPolicy.fetchesOnForeground(none, now: now), "no push yet: nothing unfinished")
    }

    /// Without the service running per push, a recent fetch says nothing about since.
    func testNoServicePushesOrNoTokenAlwaysFetches() {
        var silent = state()
        silent.pushesArrive = false
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(silent, now: now))
        var resync = state()
        resync.hasChangeToken = false
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(resync, now: now), "a resync is owed")
    }

    func testOnlyTheStampedPushSkipsItsFetch() {
        XCTAssertFalse(AppFetchPolicy.fetchesAfterPush("push-1", wholePushID: "push-1"))
        XCTAssertTrue(AppFetchPolicy.fetchesAfterPush("push-2", wholePushID: "push-1"))
        XCTAssertTrue(AppFetchPolicy.fetchesAfterPush("push-1", wholePushID: nil))
    }

    func testAWholeDeltaIsCompleteAndReadable() {
        XCTAssertTrue(RefreshResult.empty.isWholeDelta)
        var batch = RefreshResult.empty
        batch.incomplete = true
        XCTAssertFalse(batch.isWholeDelta, "one batch of many")
        var held = RefreshResult.empty
        held.unreadableRecordNames = ["moment-owner-A"]
        XCTAssertFalse(held.isWholeDelta, "a record left for a process with the keys")
    }
}
