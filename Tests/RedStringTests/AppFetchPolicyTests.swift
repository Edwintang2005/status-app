import XCTest

/// The open app reuses another process's fetch only when it took the whole
/// delta, readable (`AppFetchPolicy`, `RefreshResult.isWholeDelta`).
final class AppFetchPolicyTests: XCTestCase {
    private let now = Fixtures.t0

    func testForegroundReusesARecentCompleteFetch() {
        XCTAssertFalse(AppFetchPolicy.fetchesOnForeground(lastSyncedAt: now.addingTimeInterval(-5),
                                                          heldSince: nil, now: now))
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(lastSyncedAt: now.addingTimeInterval(-30),
                                                         heldSince: nil, now: now), "past the window")
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(lastSyncedAt: nil, heldSince: nil, now: now),
                      "never synced")
    }

    func testForegroundFetchesWhileRecordsAreHeld() {
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(lastSyncedAt: now.addingTimeInterval(-5),
                                                         heldSince: now.addingTimeInterval(-60), now: now))
    }

    func testAFutureSyncStampIsNoReason() {
        XCTAssertTrue(AppFetchPolicy.fetchesOnForeground(lastSyncedAt: now.addingTimeInterval(3600),
                                                         heldSince: nil, now: now))
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
