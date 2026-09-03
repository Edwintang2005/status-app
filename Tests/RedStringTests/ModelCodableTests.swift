import XCTest

/// Hand-written decoders for the other persisted models, plus the whole-second
/// date rule they all share.
final class ModelCodableTests: XCTestCase {
    func testLegacyPartnerMomentDefaults() throws {
        let moment = try decode(Moment.self, """
            {"id":"m1","kind":"photo","caption":"hi","senderName":"Sam",
             "sentAt":"2026-09-01T09:00:00Z","fromMe":false}
            """)
        XCTAssertFalse(moment.seen)
        XCTAssertNil(moment.seenAt)
        XCTAssertNil(moment.seenByPartnerAt)
        XCTAssertTrue(moment.uploaded, "pre-flag history must not be re-uploaded")
        XCTAssertEqual(moment.duration, 0)
        XCTAssertEqual(moment.waveform, [])
    }

    func testLegacyOwnMomentIsSeenByDefinition() throws {
        let moment = try decode(Moment.self, """
            {"id":"m1","kind":"drawing","caption":"","senderName":"Me",
             "sentAt":"2026-09-01T09:00:00Z","fromMe":true}
            """)
        XCTAssertTrue(moment.seen)
        XCTAssertEqual(Moment(kind: .voice, caption: "", senderName: "", fromMe: true).seen, true)
        XCTAssertEqual(Moment(kind: .voice, caption: "", senderName: "", fromMe: false).seen, false)
    }

    func testMomentRequiresIdentityFields() {
        XCTAssertThrowsError(try decode(Moment.self, #"{"kind":"photo"}"#),
                             "a record with no id can't be filed, so it must fail loudly")
    }

    func testStatusPayloadDecodesEmptyObject() throws {
        let payload = try decode(StatusPayload.self, "{}")
        XCTAssertEqual(payload.emoji, "💭")
        XCTAssertEqual(payload.message, "")
        XCTAssertEqual(payload.updatedAt, .distantPast)
        XCTAssertEqual(payload.nudgeCount, 0)
        XCTAssertFalse(payload.isCelebration)
    }

    func testPairingInfoDecodesWithoutUserRecordName() throws {
        let info = try decode(PairingInfo.self, """
            {"role":"participant","zoneName":"CoupleZone","zoneOwnerName":"_abc",
             "pairedAt":"2026-09-01T09:00:00Z"}
            """)
        XCTAssertEqual(info.role, .participant)
        XCTAssertNil(info.userRecordName)
    }

    func testStatusHistoryEntryTruncatesToWholeSeconds() {
        let fractional = Date(timeIntervalSince1970: Fixtures.t0.timeIntervalSince1970 + 0.73)
        let entry = StatusHistoryEntry(Fixtures.status(at: fractional), fromMe: true)
        XCTAssertEqual(entry.at, Fixtures.t0)
        XCTAssertEqual(entry.id, StatusHistoryEntry(Fixtures.status(at: Fixtures.t0), fromMe: true).id)
        XCTAssertNotEqual(entry.id, StatusHistoryEntry(Fixtures.status(at: Fixtures.t0), fromMe: false).id)
    }

    func testStatusSeenTruncatesBothDates() {
        let seen = StatusSeen(statusUpdatedAt: Fixtures.date(0.9), seenAt: Fixtures.date(1.2))
        XCTAssertEqual(seen.statusUpdatedAt, Fixtures.t0)
        XCTAssertEqual(seen.seenAt, Fixtures.date(1))
    }

    func testISO8601RoundTripDropsFractionalSeconds() throws {
        let fractional = Fixtures.date(0.5)
        let data = try JSONEncoder.shared.encode([fractional])
        let decoded = try JSONDecoder.shared.decode([Date].self, from: data)
        XCTAssertEqual(decoded, [Fixtures.t0],
                       "this is why every persisted date is truncated before being compared")
    }

    func testDurationLabel() {
        XCTAssertEqual(Fixtures.moment("v", kind: .voice).durationLabel, "0:00")
        var memo = Fixtures.moment("v", kind: .voice)
        memo.duration = 84.4
        XCTAssertEqual(memo.durationLabel, "1:24")
    }
}
