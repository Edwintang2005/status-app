import CloudKit
import XCTest

/// What a record from the shared zone becomes on this phone: dates capped to
/// the server's clock (`TrustedTime`), text and numbers bounded, and a rename
/// told apart from a new status (`StatusPayload.wordsSince`). The partner's
/// build — or a modified one — writes these fields, so none are trusted.
final class IngestTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName, ownerName: CKCurrentUserDefaultName)

    private func statusRecord(emoji: String, message: String, name: String, at date: Date) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.status,
                              recordID: CKRecord.ID(recordName: PairRole.participant.statusRecordName, zoneID: zone))
        record.encryptedValues[CloudSync.Field.emoji] = emoji
        record.encryptedValues[CloudSync.Field.message] = message
        record.encryptedValues[CloudSync.Field.displayName] = name
        record[CloudSync.Field.updatedAt] = date as CKRecordValue
        return record
    }

    // MARK: TrustedTime

    func testPlausibleCapsFutureAndPreEpochDates() {
        let server = Fixtures.t0
        XCTAssertEqual(TrustedTime.plausible(server.addingTimeInterval(86_400), serverTime: server),
                       server.addingTimeInterval(AppConfig.clockSkewAllowance))
        XCTAssertEqual(TrustedTime.plausible(Date(timeIntervalSince1970: -99_999_999_999), serverTime: server),
                       Date(timeIntervalSince1970: 0), "ISO-8601 can't read a negative year back")
        XCTAssertEqual(TrustedTime.plausible(Fixtures.t0.addingTimeInterval(-10.7), serverTime: server),
                       Fixtures.t0.addingTimeInterval(-11), "whole seconds, like every persisted date")
    }

    // MARK: Statuses

    func testRenameKeepsWhenTheWordsBegan() {
        let before = Fixtures.status("🥰", "missing you", at: Fixtures.t0)
        let renamed = statusRecord(emoji: "🥰", message: "missing you", name: "Sammy", at: Fixtures.date(100))
        let payload = CloudSync.payload(from: renamed, nudge: nil, existing: before)
        XCTAssertEqual(payload?.updatedAt, Fixtures.date(100))
        XCTAssertEqual(payload?.wordsAt, Fixtures.t0, "a rename doesn't make old words new")

        let changed = statusRecord(emoji: "☕️", message: "coffee?", name: "Sammy", at: Fixtures.date(200))
        let next = CloudSync.payload(from: changed, nudge: nil, existing: payload)
        XCTAssertNil(next?.wordsSince)
        XCTAssertEqual(next?.wordsAt, Fixtures.date(200))
    }

    func testIngestedStatusIsBounded() {
        let farFuture = Date().addingTimeInterval(10 * 365 * 86_400)
        let record = statusRecord(emoji: String(repeating: "🔥", count: 50),
                                  message: String(repeating: "a", count: 5_000),
                                  name: String(repeating: "n", count: 500),
                                  at: farFuture)
        let payload = CloudSync.payload(from: record, nudge: nil, existing: nil)
        XCTAssertEqual(payload?.emoji.count, AppConfig.statusEmojiMaxLength)
        XCTAssertEqual(payload?.message.count, AppConfig.statusMessageMaxLength)
        XCTAssertEqual(payload?.displayName.count, AppConfig.displayNameMaxLength)
        XCTAssertFalse(TrustedTime.isFuture(payload?.updatedAt ?? farFuture),
                       "a clock that ran ahead mustn't pin this status as newest")
    }

    func testNudgeCountIsClamped() {
        let nudge = CKRecord(recordType: CloudSync.RecordType.nudge,
                             recordID: CKRecord.ID(recordName: PairRole.participant.nudgeRecordName, zoneID: zone))
        nudge[CloudSync.Field.count] = Int.max as CKRecordValue
        let payload = CloudSync.payload(from: nil, nudge: nudge, existing: nil)
        XCTAssertEqual(payload?.nudgeCount, AppConfig.nudgeCountCeiling)
    }

    // MARK: Moments

    /// The two crafted values that once broke the index: a NaN made it
    /// unsavable, a negative-year date unloadable.
    func testCraftedMomentIsSanitisedAndStorable() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.moment,
                              recordID: CKRecord.ID(recordName: PairRole.participant.momentRecordName(id: "m1"),
                                                    zoneID: zone))
        record[CloudSync.Field.momentID] = "m1" as CKRecordValue
        record[CloudSync.Field.kind] = Moment.Kind.voice.rawValue as CKRecordValue
        record[CloudSync.Field.sentAt] = Date(timeIntervalSince1970: -99_999_999_999) as CKRecordValue
        record[CloudSync.Field.duration] = Double.infinity as CKRecordValue
        record.encryptedValues[CloudSync.Field.waveform] = [Double.nan, 5, -1, 0.5]
        record.encryptedValues[CloudSync.Field.caption] = String(repeating: "c", count: 10_000)

        let moment = try XCTUnwrap(CloudSync.moment(from: record, mineRole: .owner, theirsRole: .participant))
        XCTAssertEqual(moment.waveform, [0, 1, 0, 0.5])
        XCTAssertEqual(moment.duration, 0)
        XCTAssertEqual(moment.caption.count, AppConfig.captionMaxLength)
        XCTAssertGreaterThanOrEqual(moment.sentAt, Date(timeIntervalSince1970: 0))

        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert([moment])
        XCTAssertEqual(index.load().map(\.id), ["m1"], "saved and read back")
    }
}
