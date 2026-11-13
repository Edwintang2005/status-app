import CloudKit
import XCTest

/// A full resync re-delivers every moment the index doesn't hold — past its
/// cap, after a rebuild, or in the sweep to a raised cap — and none of that is news (invariant 10).
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

    /// Test records carry no server dates: each moment's creation time comes from
    /// its id here (`created`), as `metadata.createdAt` reads it off a real record.
    private func outcome(_ records: [CKRecord], known: Set<String> = [], oldestRetained: Date? = nil,
                         fullResync: Bool, newsAfter: Date? = nil,
                         created: [String: Date] = [:]) -> ParsedDelta.Outcome {
        let metadata = RecordMetadata(createdAt: { record in
                                          (record[CloudSync.Field.momentID] as? String).flatMap { created[$0] }
                                      },
                                      savedAt: { _ in nil }, isForeign: { _ in false })
        return ParsedDelta.parse(records: records, deletedIDs: [], mineRole: .owner, hidden: [], metadata: metadata)
            .outcome(mineRole: .owner, previousMine: nil, previousTheirs: nil, minePublished: true,
                     alreadyKnown: known, hidden: [], oldestRetained: oldestRetained,
                     fullResync: fullResync, newsAfter: newsAfter, now: Fixtures.date(100_000))
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

    /// News on a full resync is what the *server* created since the last complete
    /// fetch — the partner's `sentAt` doesn't come into it, so a skewed clock can't
    /// make old history new or bury a fresh moment.
    func testAFullResyncAnnouncesOnlyWhatTheServerCreatedSinceTheLastCompleteFetch() {
        let rebuilt = momentRecord(.participant, "rebuilt", at: Fixtures.date(5_000))
        let fresh = momentRecord(.participant, "fresh", at: Fixtures.date(-5_000))
        let result = outcome([rebuilt, fresh], fullResync: true, newsAfter: Fixtures.date(1_000),
                             created: ["rebuilt": Fixtures.date(500), "fresh": Fixtures.date(2_000)])
        XCTAssertEqual(Set(result.arrived.map(\.id)), ["rebuilt", "fresh"], "both are filed")
        XCTAssertEqual(result.result.newPartnerMoments.map(\.id), ["fresh"])
        XCTAssertEqual(result.fold.owedMoments.map(\.id), ["fresh"], "and only it is owed a banner")
        XCTAssertTrue(result.result.fullResync)
    }

    /// What the resync re-delivers from before the mark is history, already looked at:
    /// filed seen, so Home, the widget's memo badge and the library's dots don't count it as new.
    func testResyncedHistoryIsFiledSeen() throws {
        let created = ["old": Fixtures.date(500), "fresh": Fixtures.date(2_000), "mine": Fixtures.date(400)]
        let old = momentRecord(.participant, "old", at: Fixtures.date(500))
        let fresh = momentRecord(.participant, "fresh", at: Fixtures.date(2_000))
        let mine = momentRecord(.owner, "mine", at: Fixtures.date(400))
        let result = outcome([old, fresh, mine], fullResync: true, newsAfter: Fixtures.date(1_000), created: created)
        let byID = Dictionary(uniqueKeysWithValues: result.arrived.map { ($0.id, $0) })
        XCTAssertTrue(try XCTUnwrap(byID["old"]).seen)
        XCTAssertFalse(try XCTUnwrap(byID["fresh"]).seen, "created since: news, and unseen")
        XCTAssertTrue(try XCTUnwrap(byID["mine"]).seen, "own sends are seen anyway")

        let incremental = outcome([old], fullResync: false, newsAfter: Fixtures.date(1_000), created: created)
        XCTAssertFalse(try XCTUnwrap(incremental.arrived.first).seen, "a late offline send is still new")
        let noMark = outcome([old], fullResync: true, created: created)
        XCTAssertTrue(try XCTUnwrap(noMark.arrived.first).seen,
                      "no complete fetch yet (a new pairing, a reinstall): it's all history")
        XCTAssertTrue(noMark.fold.owedMoments.isEmpty)
    }

    /// An incremental delta's unknown moment is news whatever its date: a send
    /// that waited offline arrives with an older stamp.
    func testALateOfflineSendIsStillNews() {
        let late = momentRecord(.participant, "late", at: Fixtures.date(500))
        let result = outcome([late], fullResync: false, newsAfter: Fixtures.date(1_000),
                             created: ["late": Fixtures.date(500)])
        XCTAssertEqual(result.result.newPartnerMoments.map(\.id), ["late"])
        XCTAssertEqual(result.fold.owedMoments.map(\.id), ["late"])
    }

    func testNewsNeedsAServerTimeOnAFullResync() {
        XCTAssertTrue(AnnouncementPolicy.isNews(createdAt: nil, fullResync: false, newsAfter: nil))
        XCTAssertFalse(AnnouncementPolicy.isNews(createdAt: nil, fullResync: true, newsAfter: Fixtures.date(1)))
        XCTAssertFalse(AnnouncementPolicy.isNews(createdAt: Fixtures.date(5), fullResync: true, newsAfter: nil))
        XCTAssertTrue(AnnouncementPolicy.isNews(createdAt: Fixtures.date(5), fullResync: true, newsAfter: Fixtures.date(1)))
        XCTAssertFalse(AnnouncementPolicy.isNews(createdAt: Fixtures.date(1), fullResync: true, newsAfter: Fixtures.date(1)))
    }
}
