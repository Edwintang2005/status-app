import CloudKit
import XCTest

/// The small judgements the CloudKit actor makes on what the server returned:
/// error codes bare or per item, the share lookup failing closed, the
/// subscriptions' payloads, and the status log's confirmation mark.
final class CloudJudgementTests: XCTestCase {
    private let zone = Fixtures.zone

    private func partial(_ codes: [CKError.Code]) -> CKError {
        let errors = Dictionary(uniqueKeysWithValues: codes.enumerated().map { index, code in
            (CKRecord.ID(recordName: "r\(index)", zoneID: zone) as AnyHashable, CKError(code) as Error)
        })
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors])
    }

    // MARK: Error codes

    func testGoneIsBareOrEveryItem() {
        XCTAssertTrue(CloudSync.isAlreadyGone(CKError(.zoneNotFound)))
        XCTAssertTrue(CloudSync.isAlreadyGone(partial([.unknownItem, .userDeletedZone])))
        XCTAssertFalse(CloudSync.isAlreadyGone(partial([.unknownItem, .networkFailure])),
                       "one real failure among them must surface")
        XCTAssertFalse(CloudSync.isAlreadyGone(partial([])))
        XCTAssertFalse(CloudSync.isAlreadyGone(CKError(.networkFailure)))
    }

    func testUnknownItemExcludesTheZoneCodes() {
        XCTAssertTrue(CloudSync.isUnknownItem(partial([.unknownItem, .unknownItem])))
        XCTAssertFalse(CloudSync.isUnknownItem(CKError(.zoneNotFound)))
        XCTAssertFalse(CloudSync.isUnknownItem(partial([.unknownItem, .zoneNotFound])))
    }

    func testConflictAndExpiryMatchAnyItem() {
        XCTAssertTrue(CloudSync.isServerRecordChanged(partial([.batchRequestFailed, .serverRecordChanged])))
        XCTAssertFalse(CloudSync.isServerRecordChanged(SyncError.saveUnconfirmed))
        XCTAssertTrue(CloudSync.isTokenExpired(CKError(.changeTokenExpired)))
        XCTAssertTrue(CloudSync.isTokenExpired(partial([.changeTokenExpired])))
        XCTAssertFalse(CloudSync.isTokenExpired(partial([.zoneBusy])))
        XCTAssertTrue(CKError(.zoneBusy).itemErrors.isEmpty, "only a partial failure has items")
    }

    // MARK: The share lookup

    /// "No share" must mean the server said so: a read that failed for any
    /// other reason read as empty, and Rejoin, the replace and the close all
    /// failed open on it.
    func testTheShareLookupFailsClosed() throws {
        XCTAssertNil(try CloudSync.zoneShare(from: .failure(CKError(.zoneNotFound))))
        XCTAssertNil(try CloudSync.zoneShare(from: .failure(CKError(.unknownItem))))
        XCTAssertThrowsError(try CloudSync.zoneShare(from: .failure(CKError(.networkFailure))))
        XCTAssertThrowsError(try CloudSync.zoneShare(from: .failure(CKError(.notAuthenticated))))
        XCTAssertThrowsError(try CloudSync.zoneShare(from: nil), "no answer for the share is no answer")
        let record = CKRecord(recordType: "Status", recordID: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone))
        XCTAssertThrowsError(try CloudSync.zoneShare(from: .success(record)))
        let share = CKShare(recordZoneID: zone)
        XCTAssertEqual(share.recordID.recordName, CKRecordNameZoneWideShare, "the name the lookup asks for")
        XCTAssertIdentical(try CloudSync.zoneShare(from: .success(share)), share)
    }

    /// A new or reopened share is the server's copy: with no result for it, the
    /// unsaved local one (no URL the server knows) was handed out as the invite.
    func testASavedShareIsConfirmedByItsOwnResult() throws {
        let share = CKShare(recordZoneID: zone)
        XCTAssertThrowsError(try CloudSync.savedShare((saveResults: [:], deleteResults: [:]), share.recordID)) {
            guard case SyncError.saveUnconfirmed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CloudSync.savedShare(
            (saveResults: [share.recordID: .failure(CKError(.serverRejectedRequest))], deleteResults: [:]),
            share.recordID))
        XCTAssertIdentical(try CloudSync.savedShare(
            (saveResults: [share.recordID: .success(share)], deleteResults: [:]), share.recordID), share)
    }

    // MARK: Subscriptions

    func testSubscriptionsAreVisibleMutableAndOnlyStatusIsSilent() {
        let status = CloudSync.subscription(CloudSync.SubscriptionID.status, for: CloudSync.RecordType.status,
                                            body: CloudSync.GenericAlert.status, sound: nil)
        XCTAssertEqual(status.subscriptionID, "status-alerts")
        XCTAssertEqual(status.recordType, "Status")
        XCTAssertEqual(status.notificationInfo?.alertBody, CloudSync.GenericAlert.status)
        XCTAssertEqual(status.notificationInfo?.title, AppConfig.appName)
        XCTAssertNil(status.notificationInfo?.soundName)
        XCTAssertEqual(status.notificationInfo?.shouldSendMutableContent, true)
        let nudge = CloudSync.subscription(CloudSync.SubscriptionID.nudge, for: CloudSync.RecordType.nudge,
                                           body: CloudSync.GenericAlert.nudge, sound: "default")
        XCTAssertEqual(nudge.notificationInfo?.soundName, "default")
    }

    // MARK: The status log's mark (invariant 16)

    /// Publish A is slow; B is set and logged meanwhile; A's log save returns
    /// last. The mark must stay on B, or B's log would be owed and re-sent.
    func testALateLogSaveNeverMovesTheMarkBack() {
        let a = Fixtures.status("🙂", "A", at: Fixtures.date(0))
        let b = Fixtures.status("🌙", "B", at: Fixtures.date(60))
        var snapshot = Snapshot.empty
        snapshot.mine = b
        snapshot.myStatusLoggedAt = b.wordsAt
        snapshot.recordLogged(a)
        XCTAssertEqual(snapshot.myStatusLoggedAt, b.wordsAt)
        snapshot.myStatusLoggedAt = nil
        snapshot.recordLogged(b)
        XCTAssertEqual(snapshot.myStatusLoggedAt, b.wordsAt, "the current status's own log still marks")
    }
}
