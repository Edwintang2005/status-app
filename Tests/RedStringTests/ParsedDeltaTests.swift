import CloudKit
import XCTest

/// How a fetched delta is sorted and judged before `CloudSync.apply` writes it
/// (invariants 2, 8, 10, 14, 20): unreadable records held, reported moments
/// dropped, deletions by role, delete-then-recreate, and what counts as new or
/// as our own write. Owner's view throughout: "mine" is `owner`, the partner `participant`.
final class ParsedDeltaTests: XCTestCase {
    private let zone = Fixtures.zone
    private let me = PairRole.owner
    private var them: PairRole { me.other }

    private func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone) }

    private func status(_ role: PairRole, emoji: String? = "🥰", message: String = "missing you",
                        name: String = "Sam", at date: Date = Fixtures.t0) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.status, recordID: id(role.statusRecordName))
        // `nil` emoji: what a process without the share's keys sees.
        if let emoji {
            record.encryptedValues[CloudSync.Field.emoji] = emoji
            record.encryptedValues[CloudSync.Field.message] = message
            record.encryptedValues[CloudSync.Field.displayName] = name
        }
        record[CloudSync.Field.updatedAt] = date as CKRecordValue
        return record
    }

    private func moment(_ role: PairRole, _ momentID: String, kind: Moment.Kind = .photo,
                        at date: Date = Fixtures.t0, readable: Bool = true) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.moment,
                              recordID: id(role.momentRecordName(id: momentID)))
        record[CloudSync.Field.momentID] = momentID as CKRecordValue
        record[CloudSync.Field.kind] = kind.rawValue as CKRecordValue
        record[CloudSync.Field.sentAt] = date as CKRecordValue
        if readable { record.encryptedValues[CloudSync.Field.senderName] = "Sam" }
        return record
    }

    private func nudge(_ role: PairRole, count: Int) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.nudge, recordID: id(role.nudgeRecordName))
        record[CloudSync.Field.count] = count as CKRecordValue
        return record
    }

    private func parse(_ records: [CKRecord], deleted: [String] = [],
                       hidden: Set<String> = []) -> ParsedDelta {
        ParsedDelta.parse(records: records, deletedIDs: deleted.map(id), mineRole: me, hidden: hidden)
    }

    private func outcome(_ delta: ParsedDelta,
                         previousMine: StatusPayload? = nil,
                         previousTheirs: StatusPayload? = nil,
                         minePublished: Bool = true,
                         known: Set<String> = [],
                         hidden: Set<String> = []) -> ParsedDelta.Outcome {
        delta.outcome(mineRole: me, previousMine: previousMine, previousTheirs: previousTheirs,
                      minePublished: minePublished, alreadyKnown: known, hidden: hidden)
    }

    // MARK: Readability (invariant 2)

    func testEachTypeIsProbedOnAFieldItAlwaysWrites() {
        XCTAssertTrue(CloudSync.isReadable(status(them)))
        XCTAssertFalse(CloudSync.isReadable(status(them, emoji: nil)))
        XCTAssertTrue(CloudSync.isReadable(moment(them, "m1")))
        XCTAssertFalse(CloudSync.isReadable(moment(them, "m1", readable: false)))
        XCTAssertTrue(CloudSync.isReadable(nudge(them, count: 3)), "a nudge carries nothing encrypted")

        let legacy = moment(them, "m2", readable: false)
        legacy.encryptedValues[CloudSync.Field.caption] = "from before senderName existed"
        XCTAssertTrue(CloudSync.isReadable(legacy))

        let receipt = CKRecord(recordType: CloudSync.RecordType.receipt, recordID: id(them.receiptRecordName))
        XCTAssertFalse(CloudSync.isReadable(receipt))
        let anniversary = CKRecord(recordType: CloudSync.RecordType.anniversary,
                                   recordID: id(CloudSync.anniversaryRecordName))
        XCTAssertFalse(CloudSync.isReadable(anniversary))
    }

    /// Unreadable never means absent: listed for the token hold, and the
    /// partner's moment kept from plaintext only, for the banner.
    func testUnreadableRecordsAreHeldNotFiled() {
        let delta = parse([status(them, emoji: nil), moment(them, "m1", kind: .voice, readable: false),
                           moment(me, "mine", readable: false)])
        XCTAssertNil(delta.theirStatus)
        XCTAssertTrue(delta.moments.isEmpty)
        XCTAssertEqual(Set(delta.unreadable), [them.statusRecordName, them.momentRecordName(id: "m1"),
                                               me.momentRecordName(id: "mine")])
        XCTAssertEqual(delta.heldMoments.map(\.id), ["m1"], "only the partner's are banner material")

        let result = outcome(delta, previousTheirs: Fixtures.status("💤", "sleeping")).result
        XCTAssertTrue(result.heldPartnerStatus)
        XCTAssertEqual(result.heldPartnerMomentKinds, [.voice])
        XCTAssertEqual(result.partnerStatus?.message, "sleeping", "the held copy stands, not a placeholder")
    }

    // MARK: Sorting by role

    func testRecordsAreSortedByRoleName() {
        let delta = parse([status(me, name: "Alex"), status(them), nudge(me, count: 1), nudge(them, count: 4),
                           moment(me, "a"), moment(them, "b")])
        XCTAssertEqual(delta.myStatus?.recordID.recordName, me.statusRecordName)
        XCTAssertEqual(delta.theirStatus?.recordID.recordName, them.statusRecordName)
        XCTAssertNotNil(delta.myNudge)
        XCTAssertNotNil(delta.theirNudge)
        XCTAssertEqual(delta.moments.first { $0.id == "a" }?.fromMe, true)
        XCTAssertEqual(delta.moments.first { $0.id == "b" }?.fromMe, false)
    }

    /// Invariant 20: the record lives on in the sender's iCloud; every resync re-delivers it.
    func testReportedMomentsStayOut() {
        let delta = parse([moment(them, "reported", readable: false), moment(them, "reported-2")],
                          hidden: ["reported", "reported-2"])
        XCTAssertTrue(delta.moments.isEmpty)
        XCTAssertTrue(outcome(delta, hidden: ["reported", "reported-2"]).result.heldPartnerMomentKinds.isEmpty)
    }

    // MARK: Deletions

    func testDeletionsAreReadByRole() {
        let delta = parse([], deleted: [
            them.statusRecordName,
            me.momentRecordName(id: "mine"),
            them.momentRecordName(id: "theirs"),
            them.momentRecordName(id: "../escape"),
            me.statusLogRecordName(at: Fixtures.t0),
            them.statusLogRecordName(at: Fixtures.date(60)),
            CloudSync.anniversaryRecordName,
        ])
        XCTAssertTrue(delta.partnerErased, "how a participant unlinks")
        XCTAssertTrue(delta.anniversaryErased)
        XCTAssertEqual(Set(delta.removedMomentIDs), ["mine", "theirs"], "a path-escaping id is never acted on")
        XCTAssertEqual(delta.removedMyLogs, [Fixtures.t0])
        XCTAssertEqual(delta.removedTheirLogs, [Fixtures.date(60)])
        XCTAssertNil(outcome(delta, previousTheirs: Fixtures.status()).result.partnerStatus)
    }

    func testARecordRecreatedInTheSameDeltaWins() {
        let delta = parse([status(them)], deleted: [them.statusRecordName])
        XCTAssertFalse(delta.partnerErased)
        XCTAssertNotNil(outcome(delta).fold.theirs)
    }

    // MARK: What counts as new, and as our own write (invariant 10)

    func testNewMeansNotAlreadyStored() {
        let delta = parse([moment(them, "old", at: Fixtures.t0), moment(them, "new", at: Fixtures.date(5)),
                           moment(them, "held", readable: false)])
        let result = outcome(delta, known: ["old", "held"]).result
        XCTAssertEqual(result.newPartnerMoments.map(\.id), ["new"])
        XCTAssertTrue(result.heldPartnerMomentKinds.isEmpty, "a resync re-delivering it unreadable is not news")
        XCTAssertEqual(outcome(delta).arrived.map(\.id), ["old", "new"], "filed oldest first")
    }

    /// A full resync re-delivers our own records unchanged; only a real change
    /// (another device on this account) counts — and never an unpublished local edit.
    func testOwnRecordsChangedIsJudgedAgainstTheHeldSnapshot() {
        let held = Fixtures.status("💼", "working", at: Fixtures.t0)
        let echo = parse([status(me, emoji: "💼", message: "working", name: "Sam", at: Fixtures.t0)])
        XCTAssertFalse(outcome(echo, previousMine: held).result.ownRecordsChanged)

        let moved = parse([status(me, emoji: "🍜", message: "lunch", at: Fixtures.date(30))])
        XCTAssertTrue(outcome(moved, previousMine: held).result.ownRecordsChanged)
        XCTAssertFalse(outcome(moved, previousMine: held, minePublished: false).result.ownRecordsChanged)

        let ownMoment = parse([moment(me, "sent-elsewhere")])
        XCTAssertTrue(outcome(ownMoment).result.ownRecordsChanged)
        XCTAssertFalse(outcome(ownMoment, known: ["sent-elsewhere"]).result.ownRecordsChanged)

        let nudged = parse([nudge(me, count: 2)])
        XCTAssertTrue(outcome(nudged, previousMine: held).result.ownRecordsChanged)
    }

    // MARK: Receipts, the anniversary and its request (invariants 2, 11, 13)

    private func record(_ type: String, _ name: String) -> CKRecord {
        CKRecord(recordType: type, recordID: id(name))
    }

    func testAReadableReceiptIsAuthoritativeAndAnUnreadableOneIsHeld() throws {
        let receipt = record(CloudSync.RecordType.receipt, them.receiptRecordName)
        receipt.encryptedValues[CloudSync.Field.seenMap] = try JSONEncoder().encode(["m1": 100.0])
        receipt.encryptedValues[CloudSync.Field.statusSeenAt] = Fixtures.date(20)
        receipt.encryptedValues[CloudSync.Field.statusSeenFor] = Fixtures.date(10)
        let fold = outcome(parse([receipt])).fold
        XCTAssertTrue(fold.receiptReadable)
        XCTAssertEqual(fold.statusSeen, StatusSeen(statusUpdatedAt: Fixtures.date(10), seenAt: Fixtures.date(20)))

        let locked = parse([record(CloudSync.RecordType.receipt, them.receiptRecordName)])
        XCTAssertNil(locked.theirReceipts)
        XCTAssertEqual(locked.unreadable, [them.receiptRecordName])
        XCTAssertFalse(outcome(locked).fold.receiptReadable, "unreadable never clears the status receipt")

        XCTAssertNil(parse([record(CloudSync.RecordType.receipt, me.receiptRecordName)]).theirReceipts,
                     "our own receipt is not the partner's")
    }

    func testTheAnniversaryAndTheRequestAreReadAndDeletedExplicitly() {
        let anniversary = record(CloudSync.RecordType.anniversary, CloudSync.anniversaryRecordName)
        anniversary.encryptedValues[CloudSync.Field.startsAt] = Fixtures.t0
        anniversary.encryptedValues[CloudSync.Field.timeZone] = "Australia/Sydney"
        let request = record(CloudSync.RecordType.anniversaryRequest, CloudSync.anniversaryRequestRecordName)
        request.encryptedValues[CloudSync.Field.requestedAt] = Fixtures.date(0.6)
        let fold = outcome(parse([anniversary, request])).fold
        XCTAssertEqual(fold.anniversary?.startsAt, Fixtures.t0)
        XCTAssertEqual(fold.anniversaryRequestedAt, Fixtures.t0, "whole seconds")

        let erased = parse([], deleted: [CloudSync.anniversaryRequestRecordName, CloudSync.anniversaryRecordName])
        XCTAssertTrue(erased.requestErased)
        XCTAssertTrue(erased.anniversaryErased)
        let recreated = parse([anniversary, request],
                              deleted: [CloudSync.anniversaryRequestRecordName, CloudSync.anniversaryRecordName])
        XCTAssertFalse(recreated.requestErased)
        XCTAssertFalse(recreated.anniversaryErased)

        let locked = parse([record(CloudSync.RecordType.anniversary, CloudSync.anniversaryRecordName)])
        XCTAssertNil(locked.anniversaryRecord)
        XCTAssertFalse(locked.anniversaryErased, "unreadable never means deleted")
    }

    func testStatusLogRecordsAreReadBySide() {
        let mine = record(CloudSync.RecordType.statusLog, me.statusLogRecordName(at: Fixtures.t0))
        mine.encryptedValues[CloudSync.Field.emoji] = "🍜"
        let theirs = record(CloudSync.RecordType.statusLog, them.statusLogRecordName(at: Fixtures.date(60)))
        theirs.encryptedValues[CloudSync.Field.emoji] = "☕️"
        let locked = record(CloudSync.RecordType.statusLog, them.statusLogRecordName(at: Fixtures.date(90)))
        let delta = parse([mine, theirs, locked])
        XCTAssertEqual(delta.logEntries.map(\.fromMe), [true, false])
        XCTAssertEqual(delta.logEntries.map(\.at), [Fixtures.t0, Fixtures.date(60)])
        XCTAssertEqual(delta.unreadable, [them.statusLogRecordName(at: Fixtures.date(90))], "no placeholder entry")
    }

    func testAnUnchangedOwnNudgeIsNotAnotherDevicesWrite() {
        var held = Fixtures.status()
        held.nudgeCount = 2
        XCTAssertFalse(outcome(parse([nudge(me, count: 2)]), previousMine: held).result.ownRecordsChanged)
    }

    // MARK: Status history (invariant 14)

    func testRenamesAndEchoesAreNotLoggedAsStatuses() {
        let before = Fixtures.status("🥰", "missing you", at: Fixtures.t0)
        let renamed = parse([status(them, emoji: "🥰", message: "missing you", name: "Sammy", at: Fixtures.date(10))])
        XCTAssertNil(outcome(renamed, previousTheirs: before).partnerStatusToLog)

        let changed = parse([status(them, emoji: "☕️", message: "coffee?", at: Fixtures.date(20))])
        XCTAssertEqual(outcome(changed, previousTheirs: before).partnerStatusToLog?.message, "coffee?")

        let myEcho = parse([status(me, emoji: "🥰", message: "missing you", name: "Alex", at: Fixtures.date(30))])
        XCTAssertNil(outcome(myEcho, previousMine: before).myStatusToLog)

        let first = parse([status(them, emoji: "👋", message: "just joined", at: Fixtures.date(40))])
        XCTAssertEqual(outcome(first).partnerStatusToLog?.message, "just joined", "the first status ever is logged")

        let nudgeOnly = parse([nudge(them, count: 9)])
        XCTAssertNil(outcome(nudgeOnly, previousTheirs: before).partnerStatusToLog, "a nudge isn't a status change")
    }
}
