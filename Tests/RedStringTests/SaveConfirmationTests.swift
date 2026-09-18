import CloudKit
import XCTest

/// A save is only a save when CloudKit filed a result for the record itself.
/// A participant that marked a record delivered on the operation alone lost
/// every photo sent on patchy signal (2026-09).
final class SaveConfirmationTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "CoupleZone", ownerName: "_owner")
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

    func testDeletionIsConfirmedTheSameWay() {
        XCTAssertNoThrow(try CloudSync.confirmDeleted(result(delete: .success(())), id))
        XCTAssertThrowsError(try CloudSync.confirmDeleted(result(delete: .failure(CKError(.unknownItem))), id))
        XCTAssertThrowsError(try CloudSync.confirmDeleted(result(), id))
    }
}
