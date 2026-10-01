import CloudKit
import XCTest

/// Which of one side's records a deletion pass removes: unlink exactly as it
/// always was, and a fresh start that the partner's phone can't mistake for one.
final class ZoneClearPlanTests: XCTestCase {
    private func everyName() -> [String] {
        PairRole.allRoles.flatMap { role in
            [role.statusRecordName, role.nudgeRecordName, role.receiptRecordName, role.freshStartRecordName,
             role.momentRecordName(id: "m1"), role.statusLogRecordName(at: Fixtures.t0)]
        } + [CloudSync.anniversaryRecordName, CloudSync.anniversaryRequestRecordName,
             CKRecordNameZoneWideShare, "something-else"]
    }

    private func deleted(_ role: PairRole, _ scope: ZoneClearPlan.Scope) -> Set<String> {
        Set(everyName().filter { ZoneClearPlan.deletes($0, role: role, scope: scope) })
    }

    func testUnlinkDeletesEverythingThisSideWrote() {
        XCTAssertEqual(deleted(.owner, .unlink), [
            "status-owner", "nudge-owner", "receipt-owner", "freshstart-owner",
            PairRole.owner.momentRecordName(id: "m1"), PairRole.owner.statusLogRecordName(at: Fixtures.t0),
        ], "the owner's date goes with the zone, not record by record")
        XCTAssertEqual(deleted(.participant, .unlink), [
            "status-participant", "nudge-participant", "receipt-participant", "freshstart-participant",
            PairRole.participant.momentRecordName(id: "m1"), PairRole.participant.statusLogRecordName(at: Fixtures.t0),
            CloudSync.anniversaryRequestRecordName,
        ])
    }

    func testFreshStartDeletesHistoryOnly() {
        for role in PairRole.allRoles {
            XCTAssertEqual(deleted(role, .freshStart), [
                role.receiptRecordName, role.momentRecordName(id: "m1"), role.statusLogRecordName(at: Fixtures.t0),
            ])
            XCTAssertTrue(deleted(role, .freshStart).isSubset(of: deleted(role, .unlink)))
        }
    }

    /// The partner's phone reads a deleted status record as an unlink.
    func testFreshStartIsNotReadAsAnUnlink() {
        let zone = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName, ownerName: CKCurrentUserDefaultName)
        let deletions = everyName()
            .filter { ZoneClearPlan.deletes($0, role: .participant, scope: .freshStart) }
            .map { CKRecord.ID(recordName: $0, zoneID: zone) }
        let parsed = ParsedDelta.parse(records: [], deletedIDs: deletions, mineRole: .owner, hidden: [])

        XCTAssertFalse(parsed.partnerErased)
        XCTAssertFalse(parsed.anniversaryErased)
        XCTAssertFalse(parsed.requestErased)
        XCTAssertEqual(parsed.removedMomentIDs, ["m1"])
        XCTAssertEqual(parsed.removedTheirLogs, [Fixtures.t0])
    }
}

private extension PairRole {
    static let allRoles: [PairRole] = [.owner, .participant]
}
