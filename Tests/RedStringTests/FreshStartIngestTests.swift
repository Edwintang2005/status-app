import CloudKit
import XCTest

/// `FreshStart` records on the way in, and the epoch keeping cleared history
/// out of every later delta (invariant 2's holds included). Server dates and
/// authors are injected: a test-built `CKRecord` has neither.
final class FreshStartIngestTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName, ownerName: CKCurrentUserDefaultName)
    private let me = PairRole.owner
    private let epoch = Fixtures.date(1_000)

    private func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone) }

    private func freshStart(_ role: PairRole, stage: FreshStartRecord.Stage?, epoch: Date? = nil,
                            cleared: Date? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.freshStart, recordID: id(role.freshStartRecordName))
        if let stage { record.encryptedValues[CloudSync.Field.stage] = stage.rawValue }
        record.encryptedValues[CloudSync.Field.epoch] = epoch
        record.encryptedValues[CloudSync.Field.clearedBefore] = cleared
        return record
    }

    private func moment(_ role: PairRole, _ momentID: String, readable: Bool = true) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.moment, recordID: id(role.momentRecordName(id: momentID)))
        record[CloudSync.Field.momentID] = momentID as CKRecordValue
        record[CloudSync.Field.kind] = Moment.Kind.photo.rawValue as CKRecordValue
        record[CloudSync.Field.sentAt] = Fixtures.t0 as CKRecordValue
        if readable { record.encryptedValues[CloudSync.Field.senderName] = "Sam" }
        return record
    }

    private func statusLog(_ role: PairRole, at date: Date) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.statusLog, recordID: id(role.statusLogRecordName(at: date)))
        record.encryptedValues[CloudSync.Field.emoji] = "🥰"
        return record
    }

    /// Server dates by record name; `foreign` names were written by another account.
    private func metadata(created: [String: Date] = [:], saved: [String: Date] = [:],
                          foreign: Set<String> = []) -> RecordMetadata {
        RecordMetadata(createdAt: { created[$0.recordID.recordName] },
                       savedAt: { saved[$0.recordID.recordName] },
                       isForeign: { foreign.contains($0.recordID.recordName) })
    }

    private func committedHere() -> FreshStart {
        var held = FreshStart()
        held.mine = FreshStartRecord(stage: .committed, epoch: epoch)
        held.theirs = FreshStartRecord(stage: .agreeing, epoch: epoch)
        held.clearedBefore = epoch
        return held
    }

    // MARK: The record

    func testTheRecordIsProbedOnItsStage() {
        XCTAssertTrue(CloudSync.isReadable(freshStart(me, stage: .idle)))
        XCTAssertFalse(CloudSync.isReadable(freshStart(me, stage: nil)), "what a locked phone's extension sees")
    }

    /// An ask's epoch is its own server save time; every written date is capped
    /// there, so a mark can't keep tomorrow's history out.
    func testParsingTakesServerTimeAndCapsWrittenDates() {
        let saved = Fixtures.date(1_000.7)
        let ask = CloudSync.freshStart(from: freshStart(me, stage: .asking, epoch: Fixtures.date(50_000)), savedAt: saved)
        XCTAssertEqual(ask?.epoch, Fixtures.date(1_000), "whole seconds, from the server — not the written field")

        let agree = CloudSync.freshStart(from: freshStart(me, stage: .agreeing, epoch: Fixtures.date(400),
                                                          cleared: Fixtures.date(9_999_999)), savedAt: saved)
        XCTAssertEqual(agree?.epoch, Fixtures.date(400))
        XCTAssertEqual(agree?.clearedBefore, Fixtures.date(1_000), "capped at the record's own save")

        XCTAssertNil(CloudSync.freshStart(from: freshStart(me, stage: nil), savedAt: saved))
        XCTAssertEqual(CloudSync.freshStart(from: {
            let record = freshStart(me, stage: nil)
            record.encryptedValues[CloudSync.Field.stage] = 7
            return record
        }(), savedAt: saved)?.stage, .idle, "a stage from a newer build")
    }

    func testBothRecordsParseAndDeletionsRead() {
        let saved = [me.freshStartRecordName: epoch, me.other.freshStartRecordName: Fixtures.date(1_100)]
        let delta = ParsedDelta.parse(records: [freshStart(me, stage: .asking), freshStart(me.other, stage: .agreeing, epoch: epoch)],
                                      deletedIDs: [], mineRole: me, hidden: [], metadata: metadata(saved: saved))
        XCTAssertEqual(delta.freshStart.mine, FreshStartRecord(stage: .asking, epoch: epoch))
        XCTAssertEqual(delta.freshStart.theirs, FreshStartRecord(stage: .agreeing, epoch: epoch))
        XCTAssertTrue(delta.unreadable.isEmpty)

        let erased = ParsedDelta.parse(records: [], deletedIDs: [id(me.other.freshStartRecordName)], mineRole: me, hidden: [])
        XCTAssertTrue(erased.freshStart.theirsErased)
        let recreated = ParsedDelta.parse(records: [freshStart(me.other, stage: .idle)],
                                          deletedIDs: [id(me.other.freshStartRecordName)], mineRole: me, hidden: [])
        XCTAssertFalse(recreated.freshStart.theirsErased, "the record that exists now wins")

        let locked = ParsedDelta.parse(records: [freshStart(me.other, stage: nil)], deletedIDs: [], mineRole: me, hidden: [])
        XCTAssertEqual(locked.unreadable, [me.other.freshStartRecordName], "held like any unreadable record")
        XCTAssertTrue(locked.freshStart.isEmpty)
    }

    /// The share is read-write for both: our own record written by the partner
    /// is no consent of ours.
    func testOurRecordWrittenByAnotherAccountIsIgnored() {
        let delta = ParsedDelta.parse(records: [freshStart(me, stage: .committed, epoch: epoch),
                                                freshStart(me.other, stage: .committed, epoch: epoch)],
                                      deletedIDs: [], mineRole: me, hidden: [],
                                      freshStart: FreshStart(),
                                      metadata: metadata(foreign: [me.freshStartRecordName]))
        XCTAssertTrue(delta.foreignFreshStart)
        XCTAssertNil(delta.freshStart.mine)
        XCTAssertNotNil(delta.freshStart.theirs)

        var snapshot = Snapshot.empty
        delta.outcome(mineRole: me, previousMine: nil, previousTheirs: nil, minePublished: true,
                      alreadyKnown: [], hidden: []).fold.fold(into: &snapshot)
        XCTAssertNil(snapshot.freshStart.clearedBefore, "a forged pair commits nothing here")
    }

    /// Our record is only refused on positive proof; without our own real
    /// name nothing is judged, or a lookup that failed at pairing wedges the clear.
    func testAuthorshipNeedsOurOwnNameToJudge() {
        let known: Set<String> = [CKCurrentUserDefaultName, "_me"]
        XCTAssertFalse(CloudSync.isForeign(author: "_me", names: known))
        XCTAssertFalse(CloudSync.isForeign(author: CKCurrentUserDefaultName, names: known))
        XCTAssertTrue(CloudSync.isForeign(author: "_them", names: known))
        XCTAssertFalse(CloudSync.isForeign(author: nil, names: known))
        XCTAssertFalse(CloudSync.isForeign(author: "_them", names: [CKCurrentUserDefaultName]),
                       "our own real name unknown: nothing to judge by")
    }

    /// A batch parsed before another process folded the commit is re-judged
    /// inside the store's lock, by server creation time.
    func testTheStoresKeepClearedHistoryOutUnderTheirLocks() {
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"))
        let created = ["old": epoch.addingTimeInterval(-60), "new": epoch.addingTimeInterval(60)]
        _ = index.insertReadable([Fixtures.moment("old"), Fixtures.moment("new"), Fixtures.moment("unknown")]) {
            let isCleared = FreshStartPolicy.clearedFilter(createdAt: created, epoch: self.epoch)
            return { isCleared($0.id) }
        }
        XCTAssertEqual(Set(index.load().map(\.id)), ["new", "unknown"], "no server time: never dropped on a guess")

        let log = StatusHistoryLog(fileURL: temporaryFile("status-history.json"))
        let before = StatusHistoryEntry(emoji: "🌧️", message: "", isCelebration: false, at: Fixtures.date(10), fromMe: false)
        let after = StatusHistoryEntry(emoji: "☀️", message: "", isCelebration: false, at: Fixtures.date(20), fromMe: false)
        let logCreated = [FreshStartPolicy.LogKey(fromMe: false, at: before.at): epoch.addingTimeInterval(-1),
                          FreshStartPolicy.LogKey(fromMe: false, at: after.at): epoch]
        log.record([before, after]) {
            let isCleared = FreshStartPolicy.clearedFilter(createdAt: logCreated, epoch: self.epoch)
            return { isCleared(FreshStartPolicy.LogKey(fromMe: $0.fromMe, at: $0.at)) }
        }
        XCTAssertEqual(log.load().map(\.emoji), ["☀️"], "created at the epoch itself survives")

        XCTAssertFalse(FreshStartPolicy.clearedFilter(createdAt: created, epoch: nil)("old"))
    }

    // MARK: The epoch at ingestion

    func testHistoryFromBeforeTheEpochIsNeverFiled() {
        let created = [
            me.other.momentRecordName(id: "old"): Fixtures.date(999),
            me.other.momentRecordName(id: "new"): epoch,
            me.momentRecordName(id: "mineOld"): Fixtures.date(10),
            me.other.momentRecordName(id: "oldUnreadable"): Fixtures.date(10),
            me.other.statusLogRecordName(at: Fixtures.date(5)): Fixtures.date(5),
            me.other.statusLogRecordName(at: Fixtures.date(1_500)): Fixtures.date(1_500),
        ]
        let records = [moment(me.other, "old"), moment(me.other, "new"), moment(me, "mineOld"),
                       moment(me.other, "oldUnreadable", readable: false),
                       statusLog(me.other, at: Fixtures.date(5)), statusLog(me.other, at: Fixtures.date(1_500))]
        let delta = ParsedDelta.parse(records: records, deletedIDs: [], mineRole: me, hidden: [],
                                      freshStart: committedHere(), metadata: metadata(created: created))

        XCTAssertEqual(delta.moments.map(\.id), ["new"])
        XCTAssertEqual(delta.logEntries.map(\.at), [Fixtures.date(1_500)])
        XCTAssertEqual(delta.beforeEpoch, 4)
        XCTAssertTrue(delta.unreadable.isEmpty, "a doomed record mustn't hold the change token")
        XCTAssertTrue(delta.heldMoments.isEmpty, "nor be worded on a banner")

        let withoutEpoch = ParsedDelta.parse(records: records, deletedIDs: [], mineRole: me, hidden: [],
                                             freshStart: FreshStart(), metadata: metadata(created: created))
        XCTAssertEqual(withoutEpoch.moments.count, 3, "nothing committed, nothing kept out")
    }

    /// A full resync carries the commit and the records it clears in one delta.
    func testTheCommitInTheSameDeltaAlreadyFilters() {
        let saved = [me.freshStartRecordName: Fixtures.date(1_200), me.other.freshStartRecordName: Fixtures.date(1_300)]
        let created = [me.other.momentRecordName(id: "old"): Fixtures.date(10)]
        var held = FreshStart()
        held.mine = FreshStartRecord(stage: .agreeing, epoch: epoch)
        let delta = ParsedDelta.parse(records: [moment(me.other, "old"),
                                                freshStart(me, stage: .agreeing, epoch: epoch),
                                                freshStart(me.other, stage: .committed, epoch: epoch)],
                                      deletedIDs: [], mineRole: me, hidden: [], freshStart: held,
                                      metadata: metadata(created: created, saved: saved))
        XCTAssertTrue(delta.moments.isEmpty)
        XCTAssertEqual(delta.beforeEpoch, 1)
    }

    func testTheFoldCarriesTheRecordsIntoTheSnapshot() {
        var snapshot = Snapshot.empty
        snapshot.freshStart.mine = FreshStartRecord(stage: .agreeing, epoch: epoch)
        var fold = RefreshDelta()
        fold.freshStart = FreshStart.Incoming(theirs: FreshStartRecord(stage: .committed, epoch: epoch))
        fold.fold(into: &snapshot)
        XCTAssertEqual(snapshot.freshStart.theirs?.stage, .committed)
        XCTAssertEqual(snapshot.freshStart.clearedBefore, epoch)

        let removed = ParsedDelta.parse(records: [], deletedIDs: [id(me.other.momentRecordName(id: "x"))],
                                        mineRole: me, hidden: [])
            .outcome(mineRole: me, previousMine: nil, previousTheirs: nil, minePublished: true, alreadyKnown: [], hidden: [])
        XCTAssertEqual(removed.result.removedMoments, 1, "the NSE words a deletion push by this")
        XCTAssertTrue(removed.result.newPartnerMoments.isEmpty)
    }

    func testSnapshotDecodesWithoutTheField() throws {
        let legacy = try decode(Snapshot.self, #"{"isPaired": true, "lastSeenPartnerNudgeCount": 0}"#)
        XCTAssertEqual(legacy.freshStart, FreshStart())

        var snapshot = Snapshot.empty
        snapshot.freshStart.clearedBefore = epoch
        snapshot.freshStart.pendingIntent = .agree(epoch)
        let copy = try JSONDecoder.shared.decode(Snapshot.self, from: JSONEncoder.shared.encode(snapshot))
        XCTAssertEqual(copy.freshStart, snapshot.freshStart)
    }
}
