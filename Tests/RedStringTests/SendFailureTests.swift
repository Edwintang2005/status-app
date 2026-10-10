import CloudKit
import XCTest

/// A full iCloud is the one send failure that no retry fixes: the wording names
/// whose storage it is and automatic retries back off. No connection is quiet (the footer
/// says so); everything else is transient.
final class SendFailureTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "CoupleZone", ownerName: "_owner")

    private func partial(_ codes: [CKError.Code]) -> CKError {
        let errors = Dictionary(uniqueKeysWithValues: codes.enumerated().map { index, code in
            (CKRecord.ID(recordName: "moment-participant-\(index)", zoneID: zone) as AnyHashable,
             CKError(code) as Error)
        })
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors])
    }

    func testBareQuotaIsStorageFull() {
        XCTAssertEqual(SendFailure(CKError(.quotaExceeded)), .storageFull)
    }

    /// `confirmSaved` rethrows the record's own error, so a batch's quota also
    /// arrives inside a partial failure.
    func testQuotaInsidePartialFailureIsStorageFull() {
        XCTAssertEqual(SendFailure(partial([.batchRequestFailed, .quotaExceeded])), .storageFull)
    }

    func testNoRouteIsOffline() {
        XCTAssertEqual(SendFailure(CKError(.networkUnavailable)), .offline)
        XCTAssertEqual(SendFailure(partial([.batchRequestFailed, .networkUnavailable])), .offline)
        XCTAssertEqual(SendFailure(partial([.networkUnavailable, .quotaExceeded])), .storageFull, "quota wins")
        XCTAssertEqual(SendFailure(partial([.networkUnavailable, .serverRecordChanged])), .transient)
        XCTAssertEqual(SendFailure(partial([.batchRequestFailed])), .transient)
    }

    func testOtherFailuresAreTransient() {
        XCTAssertEqual(SendFailure(CKError(.networkFailure)), .transient, "a dropped upload isn't no route")
        XCTAssertEqual(SendFailure(partial([.serverRecordChanged])), .transient)
        XCTAssertEqual(SendFailure(CancellationError()), .transient, "a deadline is not a full iCloud")
        XCTAssertEqual(SendFailure(SyncError.saveUnconfirmed), .transient)
    }

    /// CloudKit's retry-after is honoured, bare or per item, and bounded.
    func testThrottlingCarriesTheServersDelay() {
        let now = Fixtures.t0
        let limited = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 90)])
        XCTAssertEqual(SendFailure(limited, now: now), .throttled(until: now.addingTimeInterval(90)))
        XCTAssertEqual(SendFailure(CKError(.zoneBusy), now: now),
                       .throttled(until: now.addingTimeInterval(AppConfig.throttleDefaultDelay)))
        XCTAssertEqual(SendFailure(CKError(.serviceUnavailable), now: now),
                       .throttled(until: now.addingTimeInterval(AppConfig.throttleDefaultDelay)))
        let item = CKRecord.ID(recordName: "moment-owner-a")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [item: limited]])
        XCTAssertEqual(SendFailure(partial, now: now), .throttled(until: now.addingTimeInterval(90)))
        let absurd = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 9e9)])
        XCTAssertEqual(SendFailure(absurd, now: now),
                       .throttled(until: now.addingTimeInterval(AppConfig.throttleMaxDelay)))
    }
}
