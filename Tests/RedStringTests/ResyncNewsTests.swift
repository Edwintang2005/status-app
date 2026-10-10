import CloudKit
import XCTest

/// A full resync re-delivers every moment the index doesn't hold — past its
/// 500 cap, or after a rebuild — and none of that is news (invariant 10).
final class ResyncNewsTests: XCTestCase {
    private let zone = Fixtures.zone

    private func momentRecord(_ role: PairRole, _ id: String, at date: Date) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.moment,
                              recordID: CKRecord.ID(recordName: role.momentRecordName(id: id), zoneID: zone))
        record[CloudSync.Field.momentID] = id as CKRecordValue
        record[CloudSync.Field.kind] = "photo" as CKRecordValue
        record[CloudSync.Field.sentAt] = date as CKRecordValue
        record.encryptedValues[CloudSync.Field.senderName] = "Sam"
        return record
    }

    private func outcome(_ records: [CKRecord], known: Set<String> = [], oldestRetained: Date? = nil,
                         fullResync: Bool, floor: Date? = nil) -> ParsedDelta.Outcome {
        ParsedDelta.parse(records: records, deletedIDs: [], mineRole: .owner, hidden: [])
            .outcome(mineRole: .owner, previousMine: nil, previousTheirs: nil, minePublished: true,
                     alreadyKnown: known, hidden: [], oldestRetained: oldestRetained,
                     fullResync: fullResync, announcedFloor: floor, now: Fixtures.date(100_000))
    }

    /// The index is full down to t0: a months-old photo from before it is history.
    func testMomentsPastTheCapAreNeitherNewNorFiled() {
        let old = momentRecord(.participant, "old", at: Fixtures.date(-90 * 86_400))
        let ownOld = momentRecord(.owner, "ownOld", at: Fixtures.date(-90 * 86_400))
        let result = outcome([old, ownOld], oldestRetained: Fixtures.t0, fullResync: true)
        XCTAssertTrue(result.arrived.isEmpty, "it would be trimmed straight back out")
        XCTAssertTrue(result.result.newPartnerMoments.isEmpty)
        XCTAssertFalse(result.result.ownRecordsChanged, "not another device's send either")
    }

    func testAFullResyncAnnouncesOnlyPastTheFloor() {
        let rebuilt = momentRecord(.participant, "rebuilt", at: Fixtures.date(500))
        let fresh = momentRecord(.participant, "fresh", at: Fixtures.date(2_000))
        let result = outcome([rebuilt, fresh], fullResync: true, floor: Fixtures.date(1_000))
        XCTAssertEqual(result.arrived.map(\.id), ["rebuilt", "fresh"], "both are filed")
        XCTAssertEqual(result.result.newPartnerMoments.map(\.id), ["fresh"])
        XCTAssertTrue(result.result.fullResync)
    }

    /// An incremental delta's unknown moment is news whatever its date: a send
    /// that waited offline arrives with an older stamp.
    func testALateOfflineSendIsStillNews() {
        let late = momentRecord(.participant, "late", at: Fixtures.date(500))
        let result = outcome([late], fullResync: false, floor: Fixtures.date(1_000))
        XCTAssertEqual(result.result.newPartnerMoments.map(\.id), ["late"])
    }

    func testTheRefreshClaimAppliesTheFloorOnAFullResync() {
        var snapshot = Snapshot.empty
        snapshot.lastAnnouncedMomentSentAt = Fixtures.date(1_000)
        var resync = RefreshResult(partnerStatus: nil,
                                   newPartnerMoments: [Fixtures.moment("old", at: Fixtures.date(10))])
        resync.fullResync = true
        XCTAssertNil(AnnouncementPolicy.claim(resync, previousStatus: nil, in: &snapshot).moment)

        resync.newPartnerMoments.append(Fixtures.moment("new", at: Fixtures.date(2_000)))
        XCTAssertEqual(AnnouncementPolicy.claim(resync, previousStatus: nil, in: &snapshot).moment?.id, "new")
    }

    func testAFutureFloorReadsAsNow() {
        let now = Fixtures.date(100_000)
        let ahead = now.addingTimeInterval(3 * AppConfig.clockSkewAllowance)
        XCTAssertFalse(AnnouncementPolicy.isNews(Fixtures.moment("m", at: now.addingTimeInterval(-60)),
                                                 fullResync: true, floor: ahead, now: now))
        XCTAssertTrue(AnnouncementPolicy.isNews(Fixtures.moment("m", at: now.addingTimeInterval(60)),
                                                fullResync: true, floor: ahead, now: now))
    }
}
