import CloudKit
import XCTest

/// A full iCloud is the one send failure that no retry fixes: the wording names
/// whose storage it is and automatic retries back off. Everything else is transient.
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

    func testOtherFailuresAreTransient() {
        XCTAssertEqual(SendFailure(CKError(.networkFailure)), .transient)
        XCTAssertEqual(SendFailure(partial([.serverRecordChanged])), .transient)
        XCTAssertEqual(SendFailure(CancellationError()), .transient, "a deadline is not a full iCloud")
        XCTAssertEqual(SendFailure(SyncError.saveUnconfirmed), .transient)
    }
}
