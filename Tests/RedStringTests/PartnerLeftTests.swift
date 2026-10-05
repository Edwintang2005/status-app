import CloudKit
import XCTest

/// The partner unlinking from their side (deleting their status record): seen
/// in the delta, kept as a local-only mark with the name they went by, and
/// undone if their status comes back.
final class PartnerLeftTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName, ownerName: CKCurrentUserDefaultName)

    private var paired: Snapshot {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.theirs = Fixtures.status()
        return snapshot
    }

    func testTheDeletionIsOnTheResult() {
        let deleted = [CKRecord.ID(recordName: PairRole.participant.statusRecordName, zoneID: zone)]
        let delta = ParsedDelta.parse(records: [], deletedIDs: deleted, mineRole: .owner, hidden: [])
        let outcome = delta.outcome(mineRole: .owner, previousMine: nil, previousTheirs: Fixtures.status(),
                                    minePublished: true, alreadyKnown: [], hidden: [])
        XCTAssertTrue(outcome.result.partnerLeft)
        XCTAssertNil(outcome.result.partnerStatus)

        let ownDeleted = [CKRecord.ID(recordName: PairRole.owner.statusRecordName, zoneID: zone)]
        let own = ParsedDelta.parse(records: [], deletedIDs: ownDeleted, mineRole: .owner, hidden: [])
        XCTAssertFalse(own.outcome(mineRole: .owner, previousMine: nil, previousTheirs: nil, minePublished: true,
                                   alreadyKnown: [], hidden: []).result.partnerLeft)
    }

    func testFoldKeepsWhenAndWhoInWholeSeconds() {
        var snapshot = paired
        let now = Date(timeIntervalSince1970: Fixtures.t0.timeIntervalSince1970 + 0.7)
        RefreshDelta(partnerErased: true).fold(into: &snapshot, now: now)
        XCTAssertNil(snapshot.theirs)
        XCTAssertEqual(snapshot.partnerLeftAt, Fixtures.t0)
        XCTAssertEqual(snapshot.partnerLeftName, "Sam")
        XCTAssertTrue(snapshot.partnerHasLeft)
        XCTAssertEqual(snapshot.moderatedPartnerName, "Sam", "not \"Partner\" the moment they leave")
    }

    func testADeletionWithNothingHeldIsNotALeaving() {
        var snapshot = Snapshot.empty
        RefreshDelta(partnerErased: true).fold(into: &snapshot)
        XCTAssertNil(snapshot.partnerLeftAt)
        XCTAssertFalse(snapshot.partnerHasLeft)
    }

    func testTheirStatusComingBackClearsIt() {
        var snapshot = paired
        RefreshDelta(partnerErased: true).fold(into: &snapshot)
        snapshot.partnerLeftAnnounced = true
        RefreshDelta(theirs: Fixtures.status("👋", "back", at: Fixtures.date(500))).fold(into: &snapshot)
        XCTAssertNil(snapshot.partnerLeftAt)
        XCTAssertNil(snapshot.partnerLeftName)
        XCTAssertFalse(snapshot.partnerLeftAnnounced)
        XCTAssertFalse(snapshot.partnerHasLeft)
    }

    func testRoundTripAndLegacyFallback() throws {
        var snapshot = paired
        RefreshDelta(partnerErased: true).fold(into: &snapshot, now: Fixtures.t0)
        snapshot.partnerLeftAnnounced = true
        let decoded = try JSONDecoder.shared.decode(Snapshot.self, from: JSONEncoder.shared.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)

        let legacy = try decode(Snapshot.self, #"{"isPaired": true}"#)
        XCTAssertNil(legacy.partnerLeftAt)
        XCTAssertNil(legacy.partnerLeftName)
        XCTAssertFalse(legacy.partnerLeftAnnounced)
    }
}
