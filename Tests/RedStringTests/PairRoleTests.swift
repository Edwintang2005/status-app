import XCTest

final class PairingInfoTests: XCTestCase {
    func testSameZoneIgnoresPairedAtAndAccount() {
        let a = PairingInfo(role: .participant, zoneName: "CoupleZone", zoneOwnerName: "_owner",
                            pairedAt: Fixtures.t0, userRecordName: "_me")
        let b = PairingInfo(role: .participant, zoneName: "CoupleZone", zoneOwnerName: "_owner",
                            pairedAt: Fixtures.date(0.5), userRecordName: nil)
        XCTAssertTrue(a.sameZone(as: b), "a fractional in-memory pairedAt must not break the guard")
        var other = a
        other.zoneOwnerName = "_someoneElse"
        XCTAssertFalse(a.sameZone(as: other))
        other = a
        other.role = .owner
        XCTAssertFalse(a.sameZone(as: other))
    }
}

/// Record names are the whole addressing scheme — neither device knows the
/// other's CloudKit user ID.
final class PairRoleTests: XCTestCase {
    func testOtherRole() {
        XCTAssertEqual(PairRole.owner.other, .participant)
        XCTAssertEqual(PairRole.participant.other, .owner)
    }

    func testFixedRecordNamesDiffer() {
        XCTAssertNotEqual(PairRole.owner.statusRecordName, PairRole.participant.statusRecordName)
        XCTAssertNotEqual(PairRole.owner.nudgeRecordName, PairRole.participant.nudgeRecordName)
        XCTAssertNotEqual(PairRole.owner.receiptRecordName, PairRole.participant.receiptRecordName)
    }

    func testMomentRecordNameRoundTrip() {
        let name = PairRole.owner.momentRecordName(id: "ABC-123")
        XCTAssertEqual(name, "moment-owner-ABC-123")
        XCTAssertEqual(PairRole.owner.momentID(fromRecordName: name), "ABC-123")
        XCTAssertNil(PairRole.participant.momentID(fromRecordName: name), "the other role's records aren't ours")
        XCTAssertNil(PairRole.owner.momentID(fromRecordName: "status-owner"))
    }

    func testStatusLogRecordNameUsesWholeSeconds() {
        let fractional = Fixtures.date(0.9)
        let name = PairRole.participant.statusLogRecordName(at: fractional)
        XCTAssertEqual(name, "statuslog-participant-\(Int(Fixtures.t0.timeIntervalSince1970))")
        XCTAssertEqual(PairRole.participant.statusLogDate(fromRecordName: name), Fixtures.t0,
                       "a republish of the same status must overwrite, not duplicate")
        XCTAssertNil(PairRole.owner.statusLogDate(fromRecordName: name))
        XCTAssertNil(PairRole.participant.statusLogDate(fromRecordName: "statuslog-participant-x"))
    }
}
