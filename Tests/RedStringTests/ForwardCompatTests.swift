import CloudKit
import XCTest

/// What survives data this build didn't expect (invariants 5, 15, 23): a moment
/// kind from a newer build, one bad entry in a store file, a partner-written
/// date no decoder reads back, an unreadable status log — and the index's
/// cache and compact waveforms, which must change none of it.
final class ForwardCompatTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName, ownerName: CKCurrentUserDefaultName)

    // MARK: Unknown moment kinds

    func testAnUnknownKindIsKeptUnderItsOwnName() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.moment,
                              recordID: CKRecord.ID(recordName: PairRole.participant.momentRecordName(id: "h1"),
                                                    zoneID: zone))
        record[CloudSync.Field.momentID] = "h1" as CKRecordValue
        record[CloudSync.Field.kind] = "heartbeat" as CKRecordValue
        record[CloudSync.Field.sentAt] = Fixtures.t0 as CKRecordValue
        record.encryptedValues[CloudSync.Field.senderName] = "Sam"

        let parsed = ParsedDelta.parse(records: [record], deletedIDs: [], mineRole: .owner, hidden: [])
        XCTAssertEqual(parsed.moments.map(\.kind), [.unsupported("heartbeat")], "filed, not dropped past the token")
        XCTAssertTrue(parsed.unreadable.isEmpty)
        let moment = try XCTUnwrap(parsed.moments.first)
        XCTAssertFalse(moment.isPicture)
        XCTAssertFalse(moment.kind.isSupported)

        let url = temporaryFile("moments-index.json")
        let index = MomentIndex(fileURL: url, onCorrupt: {})
        index.insert([moment])
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"heartbeat\""), "the build that knows it reads it back as itself")
        XCTAssertEqual(index.load().first?.kind, .unsupported("heartbeat"))
    }

    func testKnownKindsKeepTheirNames() throws {
        for kind in [Moment.Kind.photo, .drawing, .voice] {
            XCTAssertEqual(Moment.Kind(rawValue: kind.rawValue), kind)
            let data = try JSONEncoder.shared.encode(Fixtures.moment("m", kind: kind))
            XCTAssertEqual(try JSONDecoder.shared.decode(Moment.self, from: data).kind, kind)
        }
    }

    // MARK: One bad entry

    private func indexFile(_ entries: [String]) throws -> (MomentIndex, URL, () -> Int) {
        let url = temporaryFile("moments-index.json")
        try Data("[\(entries.joined(separator: ","))]".utf8).write(to: url)
        let hits = Counter()
        return (MomentIndex(fileURL: url, onCorrupt: { hits.value += 1 }), url, { hits.value })
    }

    private func entry(_ id: String, uploaded: Bool = true, fromMe: Bool = false) -> String {
        #"{"id":"\#(id)","kind":"photo","caption":"","senderName":"Sam","sentAt":"2025-09-01T10:00:00Z","fromMe":\#(fromMe),"uploaded":\#(uploaded)}"#
    }

    func testOneBadEntryCostsOnlyItself() throws {
        let broken = #"{"id":"bad","kind":"photo"}"#
        let (index, url, corrupt) = try indexFile([entry("a"), broken, entry("unsent", uploaded: false, fromMe: true)])
        XCTAssertEqual(Set(index.load().map(\.id)), ["a", "unsent"], "the unsent send next to it survives")
        XCTAssertEqual(corrupt(), 0, "a plain read leaves the file be")

        index.markSeen(ids: ["a"])
        XCTAssertEqual(corrupt(), 1, "a write asks the zone to refill what was skipped")
        let sidecar = try String(contentsOf: url.appendingPathExtension("corrupt"), encoding: .utf8)
        XCTAssertTrue(sidecar.contains("\"bad\""), "the skipped bytes are kept")
        XCTAssertEqual(Set(index.load().map(\.id)), ["a", "unsent"])
    }

    func testUnsentSendsAreSalvagedFromAnOldSidecarOnce() throws {
        let url = temporaryFile("moments-index.json")
        let sidecar = url.appendingPathExtension("corrupt")
        try Data("[\(entry("lost", uploaded: false, fromMe: true)),\(entry("noMedia", uploaded: false, fromMe: true)),\(entry("theirs"))]".utf8)
            .write(to: sidecar)
        let index = MomentIndex(fileURL: url, onCorrupt: {})
        index.insert([Fixtures.moment("current")])

        let salvaged = index.salvagePendingUploads { $0.id != "noMedia" }
        XCTAssertEqual(salvaged.map(\.id), ["lost"])
        XCTAssertEqual(Set(index.load().map(\.id)), ["current", "lost"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.appendingPathExtension("salvaged").path),
                      "looked at once, the bytes still kept")
        XCTAssertTrue(index.salvagePendingUploads { _ in true }.isEmpty)
    }

    func testTheStatusLogSkipsABadEntry() throws {
        let url = temporaryFile("status-history.json")
        let good = #"{"emoji":"🍜","message":"lunch","isCelebration":false,"at":"2025-09-01T10:00:00Z","fromMe":true}"#
        try Data("[\(good),{\"at\":5}]".utf8).write(to: url)
        let hits = Counter()
        let log = StatusHistoryLog(fileURL: url, onCorrupt: { hits.value += 1 })
        XCTAssertEqual(log.load().map(\.message), ["lunch"])
        XCTAssertEqual(hits.value, 0, "a plain read leaves the file be")
        log.record(Fixtures.status(at: Fixtures.date(1)), fromMe: false)
        XCTAssertEqual(log.load().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        XCTAssertEqual(hits.value, 1, "the zone is asked to refill what was lost")
    }

    /// Like the index: the first write saves the readable rest, even with nothing new to add.
    func testTheStatusLogSavesTheRestOnTheFirstWrite() throws {
        let url = temporaryFile("status-history.json")
        let good = #"{"emoji":"🍜","message":"lunch","isCelebration":false,"at":"2025-09-01T10:00:00Z","fromMe":true}"#
        try Data("[\(good),{\"at\":5}]".utf8).write(to: url)
        let log = StatusHistoryLog(fileURL: url, onCorrupt: {})
        let existing = try XCTUnwrap(log.load().first)
        log.record([existing])
        let stored = try JSONDecoder.shared.decode(LossyArray<StatusHistoryEntry>.self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.dropped, 0)
        XCTAssertEqual(stored.elements.map(\.message), ["lunch"])
    }

    // MARK: Unreadable isn't empty

    func testAnUnreadableStatusLogIsLeftUntouched() throws {
        let url = temporaryFile("status-history.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let log = StatusHistoryLog(fileURL: url, onCorrupt: {})
        log.record(Fixtures.status(), fromMe: true)
        XCTAssertTrue(log.readFailed)
        XCTAssertNil(log.loadReadable())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "nothing was written over it")
    }

    // MARK: Partner-written dates

    func testReceiptAndRequestDatesAreBounded() throws {
        let receipt = CKRecord(recordType: CloudSync.RecordType.receipt,
                               recordID: CKRecord.ID(recordName: PairRole.participant.receiptRecordName, zoneID: zone))
        let negativeYear = Date(timeIntervalSince1970: -99_999_999_999)
        receipt.encryptedValues[CloudSync.Field.statusSeenAt] = negativeYear
        receipt.encryptedValues[CloudSync.Field.statusSeenFor] = Date().addingTimeInterval(400 * 86_400)
        let seen = try XCTUnwrap(CloudSync.statusSeen(from: receipt))
        XCTAssertEqual(seen.seenAt, Date(timeIntervalSince1970: 0))
        XCTAssertFalse(TrustedTime.isFuture(seen.statusUpdatedAt))

        let request = CKRecord(recordType: CloudSync.RecordType.anniversaryRequest,
                               recordID: CKRecord.ID(recordName: CloudSync.anniversaryRequestRecordName, zoneID: zone))
        request.encryptedValues[CloudSync.Field.requestedAt] = negativeYear
        XCTAssertEqual(CloudSync.anniversaryRequestDate(from: request), Date(timeIntervalSince1970: 0))

        // The snapshot holding them still round-trips.
        var snapshot = Snapshot.empty
        snapshot.myStatusSeenByPartner = seen
        snapshot.anniversaryRequestedAt = CloudSync.anniversaryRequestDate(from: request)
        let data = try JSONEncoder.shared.encode(snapshot)
        XCTAssertEqual(try JSONDecoder.shared.decode(Snapshot.self, from: data), snapshot)
    }

    func testAnAnniversaryMayPredate1970ButNotAnyCouple() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.anniversary,
                              recordID: CKRecord.ID(recordName: CloudSync.anniversaryRecordName, zoneID: zone))
        let wedding1965 = Date(timeIntervalSince1970: -157_766_400)
        record.encryptedValues[CloudSync.Field.startsAt] = wedding1965
        XCTAssertEqual(CloudSync.anniversary(from: record)?.startsAt, wedding1965)

        record.encryptedValues[CloudSync.Field.startsAt] = Date(timeIntervalSince1970: -99_999_999_999)
        XCTAssertEqual(CloudSync.anniversary(from: record)?.startsAt, Anniversary.earliest)
        record.encryptedValues[CloudSync.Field.startsAt] = Date().addingTimeInterval(400 * 86_400)
        XCTAssertFalse(TrustedTime.isFuture(try XCTUnwrap(CloudSync.anniversary(from: record)).startsAt))
    }

    /// One field no decoder reads back costs that field, never the watermarks beside it.
    func testABadNestedFieldCostsOnlyItself() throws {
        let json = #"""
        {"isPaired":true,"lastSeenPartnerNudgeCount":12,"lastAnnouncedMomentSentAt":"2025-09-01T10:00:00Z",
         "partnerStatusSeen":{"statusUpdatedAt":"-4712-01-01T12:00:00Z","seenAt":"2025-09-01T10:00:00Z"},
         "anniversary":{"startsAt":"nonsense"},
         "freshStart":{"clearedBefore":"2025-08-01T10:00:00Z"}}
        """#
        let snapshot = try decode(Snapshot.self, json)
        XCTAssertTrue(snapshot.isPaired)
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 12)
        XCTAssertNotNil(snapshot.lastAnnouncedMomentSentAt)
        XCTAssertNotNil(snapshot.freshStart.clearedBefore, "the fresh start's mark survives (invariant 24)")
        XCTAssertNil(snapshot.partnerStatusSeen)
        XCTAssertNil(snapshot.anniversary)
    }

    func testAnniversaryAndStatusSeenDecodeWithFallbacks() throws {
        let anniversary = try decode(Anniversary.self, #"{"startsAt":"2020-02-02T10:00:00Z"}"#)
        XCTAssertEqual(anniversary.timeZoneID, TimeZone.current.identifier)
        let seen = try decode(StatusSeen.self, #"{"statusUpdatedAt":"2025-09-01T10:00:00Z"}"#)
        XCTAssertEqual(seen.seenAt, seen.statusUpdatedAt)
    }

    // MARK: The index's cache and compact waveforms

    func testWaveformsAreStoredCompactlyAndReadBothWays() throws {
        let url = temporaryFile("moments-index.json")
        let index = MomentIndex(fileURL: url, onCorrupt: {})
        var memo = Fixtures.moment("v", kind: .voice)
        memo.waveform = [0, 0.25, 0.5, 1]
        index.insert([memo])
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("waveformBytes"))
        XCTAssertFalse(json.contains("\"waveform\""))
        let stored = try XCTUnwrap(MomentIndex(fileURL: url, onCorrupt: {}).load().first?.waveform)
        XCTAssertEqual(stored.count, 4)
        for (a, b) in zip(stored, memo.waveform) { XCTAssertEqual(a, b, accuracy: 1.0 / 255) }

        let legacy = try decode(Moment.self, #"{"id":"v","kind":"voice","caption":"","senderName":"Sam","sentAt":"2025-09-01T10:00:00Z","fromMe":false,"waveform":[0.5,1]}"#)
        XCTAssertEqual(legacy.waveform, [0.5, 1], "an index written before the compact form")
        let snapshotJSON = try JSONEncoder.shared.encode(memo)
        XCTAssertEqual(try JSONDecoder.shared.decode(Moment.self, from: snapshotJSON), memo,
                       "the snapshot keeps exact doubles")
    }

    /// Another process's write replaces the file; the next load must see it.
    func testTheCacheFollowsAnotherProcesssWrite() {
        let url = temporaryFile("moments-index.json")
        let here = MomentIndex(fileURL: url, onCorrupt: {})
        let there = MomentIndex(fileURL: url, onCorrupt: {})
        here.insert([Fixtures.moment("a")])
        XCTAssertEqual(here.load().map(\.id), ["a"])
        there.insert([Fixtures.moment("b", at: Fixtures.date(10))])
        XCTAssertEqual(here.load().map(\.id), ["b", "a"])
        there.clear()
        XCTAssertEqual(here.load(), [])
    }

    func testTheMergeKeepsLocalFieldsAndOrdersTies() {
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert([Fixtures.moment("x"), Fixtures.moment("y")])
        index.markSeen(ids: ["x"])
        let all = index.insert([Fixtures.moment("x", seen: false), Fixtures.moment("z")])
        XCTAssertEqual(all.map(\.id), ["z", "y", "x"], "ties by id, the same every time")
        XCTAssertEqual(all.first { $0.id == "x" }?.seen, true)
    }
}

/// A counter a non-escaping test closure can bump.
private final class Counter: @unchecked Sendable {
    var value = 0
}
