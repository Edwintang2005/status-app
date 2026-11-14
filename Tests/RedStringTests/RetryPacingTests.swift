import CloudKit
import XCTest

/// Every automatic retry's holds in one place (`RetryPacing`): a full iCloud and
/// a throttle hold every pass; a refused send waits; a failing one backs off.
final class RetryPacingTests: XCTestCase {
    func testAFullICloudHoldsEveryAutomaticPassForItsInterval() {
        var pacing = RetryPacing()
        let interval = AppConfig.storageFullRetryInterval
        XCTAssertTrue(pacing.allowsAutomatic(now: Fixtures.t0))
        pacing.noteFailure(CKError(.quotaExceeded), now: Fixtures.t0)
        XCTAssertFalse(pacing.allowsAutomatic(now: Fixtures.date(interval - 1)))
        XCTAssertFalse(pacing.allowsAutomatic(.upload("m"), now: Fixtures.date(interval - 1)), "per send too")
        XCTAssertTrue(pacing.allowsAutomatic(now: Fixtures.date(interval)))
        XCTAssertTrue(pacing.allowsAutomatic(now: Fixtures.date(-60)), "a stamp ahead of the clock doesn't hold")
        pacing.noteSuccess()
        XCTAssertNil(pacing.storageFullAt, "anything landing proves there's room")
    }

    func testAThrottleHoldsUntilItsRetryAfterAndTheLatestWins() {
        var pacing = RetryPacing()
        pacing.noteFailure(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0]), now: Fixtures.t0)
        pacing.noteFailure(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0]), now: Fixtures.t0)
        XCTAssertEqual(pacing.throttledUntil, Fixtures.date(120))
        XCTAssertFalse(pacing.allowsAutomatic(now: Fixtures.date(119)))
        XCTAssertTrue(pacing.allowsAutomatic(now: Fixtures.date(120)))
    }

    func testOfflineHoldsNothing() {
        var pacing = RetryPacing()
        XCTAssertEqual(pacing.noteFailure(CKError(.networkUnavailable), now: Fixtures.t0), .offline)
        XCTAssertEqual(pacing, RetryPacing())
    }

    /// A refused send waits its interval; the others don't; sending clears it.
    func testARefusedSendWaitsAloneUntilCleared() {
        var pacing = RetryPacing()
        let interval = AppConfig.rejectedUploadRetryInterval
        pacing.hold(.upload("a"), for: interval, now: Fixtures.t0)
        XCTAssertFalse(pacing.allowsAutomatic(.upload("a"), now: Fixtures.date(interval - 1)))
        XCTAssertTrue(pacing.allowsAutomatic(.upload("b"), now: Fixtures.t0))
        XCTAssertTrue(pacing.allowsAutomatic(.caption("a"), now: Fixtures.t0), "a caption is its own send")
        XCTAssertTrue(pacing.allowsAutomatic(.upload("a"), now: Fixtures.date(interval)))
        pacing.hold(.upload("a"), for: interval, now: Fixtures.t0)
        pacing.clear(.upload("a"))
        XCTAssertTrue(pacing.allowsAutomatic(.upload("a"), now: Fixtures.t0))
    }

    func testRepeatedFailuresDoubleUpToTheCap() {
        var pacing = RetryPacing()
        pacing.backOff(.status, now: Fixtures.t0)
        let first = RetryPacing.backOffDelay(failures: 1)
        XCTAssertFalse(pacing.allowsAutomatic(.status, now: Fixtures.date(first - 1)))
        XCTAssertTrue(pacing.allowsAutomatic(.status, now: Fixtures.date(first)))
        pacing.backOff(.status, now: Fixtures.t0)
        XCTAssertFalse(pacing.allowsAutomatic(.status, now: Fixtures.date(first)), "the second wait is longer")
        XCTAssertEqual(RetryPacing.backOffDelay(failures: 2), first * 2)
        XCTAssertEqual(RetryPacing.backOffDelay(failures: 30), AppConfig.statusRetryMaxDelay)
        pacing.clear(.status)
        XCTAssertTrue(pacing.allowsAutomatic(.status, now: Fixtures.t0))
    }
}
