import CloudKit
import XCTest

/// A save is only a save when CloudKit filed a result for the record itself.
/// A participant that marked a record delivered on the operation alone lost
/// every photo sent on patchy signal (2026-09).
final class SaveConfirmationTests: XCTestCase {
    private let zone = Fixtures.zone
    private var id: CKRecord.ID { CKRecord.ID(recordName: "moment-participant-A", zoneID: zone) }

    private func result(save: Result<CKRecord, Error>? = nil,
                        delete: Result<Void, Error>? = nil) -> CloudSync.ModifyResult {
        (saveResults: save.map { [id: $0] } ?? [:],
         deleteResults: delete.map { [id: $0] } ?? [:])
    }

    func testSavedRecordIsReturned() throws {
        let record = CKRecord(recordType: "Moment", recordID: id)
        XCTAssertEqual(try CloudSync.confirmSaved(result(save: .success(record)), id).recordID, id)
    }

    func testPerRecordFailureThrows() {
        let failure = CKError(.networkFailure)
        XCTAssertThrowsError(try CloudSync.confirmSaved(result(save: .failure(failure)), id)) { error in
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
    }

    func testMissingResultIsNotASave() {
        XCTAssertThrowsError(try CloudSync.confirmSaved(result(), id)) { error in
            guard case SyncError.saveUnconfirmed? = error as? SyncError else {
                return XCTFail("expected saveUnconfirmed, got \(error)")
            }
        }
    }

    /// The status log prune: gone or never there leaves the local log; anything else stays for next time.
    func testOnlyConfirmedPrunesLeaveTheLocalLog() {
        let ids = (0..<4).map { CKRecord.ID(recordName: "statuslog-owner-\($0)", zoneID: zone) }
        let stale = ids.enumerated().map { CloudSync.StaleStatusLog(id: $1, at: Fixtures.date(Double($0))) }
        let result: CloudSync.ModifyResult = (saveResults: [:], deleteResults: [
            ids[0]: .success(()),
            ids[1]: .failure(CKError(.unknownItem)),
            ids[2]: .failure(CKError(.networkFailure)),
        ])
        XCTAssertEqual(CloudSync.confirmedPrunes(result, stale), [Fixtures.date(0), Fixtures.date(1)])
    }

    func testDeletionIsConfirmedTheSameWay() {
        XCTAssertNoThrow(try CloudSync.confirmDeleted(result(delete: .success(())), id))
        XCTAssertThrowsError(try CloudSync.confirmDeleted(result(delete: .failure(CKError(.unknownItem))), id))
        XCTAssertThrowsError(try CloudSync.confirmDeleted(result(), id))
    }
}
