import CloudKit
import XCTest

/// Status history dedups by `(fromMe, whole-second wordsAt)` across its two
/// feeds (CLAUDE.md invariant 14) and mirrors cloud deletions.
final class StatusHistoryLogTests: XCTestCase {
    private var corruptHits = 0

    private func makeLog() -> (StatusHistoryLog, URL) {
        let url = temporaryFile("status-history.json")
        return (StatusHistoryLog(fileURL: url, onCorrupt: { [self] in corruptHits += 1 }), url)
    }

    /// STORE-10, as for the index: a file healed before the locked re-read is kept.
    func testAFileHealedBeforeTheLockedRereadIsKept() throws {
        let (log, url) = makeLog()
        StatusHistoryLog(fileURL: url, onCorrupt: {}).record(Fixtures.status(at: Fixtures.t0), fromMe: true)
        let healthy = try Data(contentsOf: url)
        try Data("{ not json".utf8).write(to: url)
        log.beforeLockedReread = { try? healthy.write(to: url, options: .atomic) }

        XCTAssertEqual(log.load().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        XCTAssertEqual(corruptHits, 0)
    }

    func testSameStatusFromBothFeedsIsOneEntry() {
        let (log, _) = makeLog()
        let payload = Fixtures.status(at: Fixtures.t0)
        log.record(payload, fromMe: true)
        // The `StatusLog` record echo: same second, built as an entry.
        log.record([StatusHistoryEntry(payload, fromMe: true)])
        XCTAssertEqual(log.load().count, 1)
    }

    func testFractionalAndWholeSecondCollapse() {
        let (log, _) = makeLog()
        log.record(Fixtures.status(at: Fixtures.date(0.4)), fromMe: false)
        log.record(Fixtures.status(at: Fixtures.t0), fromMe: false)
        XCTAssertEqual(log.load().count, 1)
    }

    func testBothSidesInTheSameSecondAreDistinct() {
        let (log, _) = makeLog()
        log.record(Fixtures.status(at: Fixtures.t0), fromMe: true)
        log.record(Fixtures.status(at: Fixtures.t0), fromMe: false)
        XCTAssertEqual(log.load().count, 2)
    }

    func testPlaceholderStatusesAreSkipped() {
        let (log, _) = makeLog()
        log.record(.placeholder, fromMe: false)
        XCTAssertEqual(log.load(), [])
    }

    func testNewestFirstAndExistingEntriesWin() {
        let (log, _) = makeLog()
        log.record(Fixtures.status("💼", "working", at: Fixtures.date(-60)), fromMe: true)
        log.record(Fixtures.status("🍜", "ramen", at: Fixtures.t0), fromMe: true)
        log.record(Fixtures.status("💼", "renamed", at: Fixtures.date(-60)), fromMe: true)
        let entries = log.load()
        XCTAssertEqual(entries.map(\.message), ["ramen", "working"])
    }

    func testRemoveMirrorsCloudDeletionByWholeSecond() {
        let (log, _) = makeLog()
        log.record(Fixtures.status(at: Fixtures.t0), fromMe: true)
        log.record(Fixtures.status(at: Fixtures.t0), fromMe: false)
        log.remove(fromMe: true, at: [Fixtures.date(0.7)])
        let left = log.load()
        XCTAssertEqual(left.count, 1)
        XCTAssertFalse(left[0].fromMe, "only the named side's entry goes")
    }

    func testCapKeepsTheNewest() {
        let (log, _) = makeLog()
        let entries = (0..<(AppConfig.statusHistoryLimit + 5)).map {
            StatusHistoryEntry(Fixtures.status(at: Fixtures.date(Double($0))), fromMe: true)
        }
        log.record(entries)
        let kept = log.load()
        XCTAssertEqual(kept.count, AppConfig.statusHistoryLimit)
        XCTAssertEqual(kept.first?.at, Fixtures.date(Double(AppConfig.statusHistoryLimit + 4)))
    }

    func testCorruptFileIsPreserved() throws {
        let (log, url) = makeLog()
        try Data("{oops".utf8).write(to: url)
        XCTAssertEqual(log.load(), [])
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("corrupt")), Data("{oops".utf8))
        XCTAssertEqual(corruptHits, 1, "the change tokens go, so the zone's StatusLog records refill it")
        log.record(Fixtures.status(), fromMe: true)
        XCTAssertEqual(log.load().count, 1)
    }

    func testClearRemovesTheSidecarToo() throws {
        let (log, url) = makeLog()
        try Data("{oops".utf8).write(to: url)
        _ = log.load()
        log.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        XCTAssertEqual(log.load(), [])
    }

    func testDuplicatesCollapse() throws {
        let (log, url) = makeLog()
        let entry = StatusHistoryEntry(Fixtures.status(), fromMe: true)
        try JSONEncoder.shared.encode([entry, entry]).write(to: url)
        XCTAssertEqual(log.load().count, 1)
    }

    /// Another process's write replaces the file; the cached list must not hide it.
    func testTheCacheFollowsAnotherProcesssWrite() {
        let (here, url) = makeLog()
        let there = StatusHistoryLog(fileURL: url, onCorrupt: {})
        here.record(Fixtures.status(at: Fixtures.t0), fromMe: true)
        XCTAssertEqual(here.load().count, 1)
        there.record(Fixtures.status(at: Fixtures.date(10)), fromMe: false)
        XCTAssertEqual(here.load().count, 2)
        there.remove(fromMe: true, at: [Fixtures.t0])
        XCTAssertEqual(here.load().map(\.fromMe), [false])
        there.clear()
        XCTAssertEqual(here.load(), [])
    }

    // MARK: Owed log records (statuses set offline)

    func testOursAreOwedUntilALogRecordConfirmsThem() {
        let (log, _) = makeLog()
        log.record(Fixtures.status("☕️", "coffee", at: Fixtures.t0), fromMe: true, unlogged: true)
        log.record(Fixtures.status("💼", "work", at: Fixtures.date(60)), fromMe: true, unlogged: true)
        XCTAssertEqual(log.unloggedOwn(limit: 10, excluding: nil, after: nil).map(\.message), ["work", "coffee"])
        XCTAssertEqual(log.unloggedOwn(limit: 10, excluding: Fixtures.date(60), after: nil).map(\.message), ["coffee"],
                       "never the current status: its own publish logs it")
        XCTAssertEqual(log.unloggedOwn(limit: 10, excluding: nil, after: Fixtures.date(30)).map(\.message), ["work"],
                       "never from before a fresh start")

        log.markLogged(at: [Fixtures.date(60)])
        XCTAssertEqual(log.unloggedOwn(limit: 10, excluding: nil, after: nil).map(\.message), ["coffee"])
        // Its record arriving from the zone (another device of ours, a resync) settles it too.
        log.record([StatusHistoryEntry(Fixtures.status("☕️", "coffee", at: Fixtures.t0), fromMe: true)], fromLogRecords: true)
        XCTAssertTrue(log.unloggedOwn(limit: 10, excluding: nil, after: nil).isEmpty)
    }

    /// The current `Status` record's entry is no proof its log landed.
    func testOnlyALogRecordSettlesAnEntry() {
        let (log, _) = makeLog()
        let coffee = Fixtures.status("☕️", "coffee", at: Fixtures.t0)
        log.record(coffee, fromMe: true, unlogged: true)
        log.record(coffee, fromMe: true)
        XCTAssertEqual(log.unloggedOwn(limit: 10, excluding: nil, after: nil).count, 1)
    }

    func testOnlyTheNewestTheCloudKeepsAreOwed() {
        let (log, _) = makeLog()
        for second in 0..<(AppConfig.statusLogLimit + 5) {
            log.record(Fixtures.status("☕️", "\(second)", at: Fixtures.date(Double(second))), fromMe: true, unlogged: true)
        }
        let owed = log.unloggedOwn(limit: 1_000, excluding: nil, after: nil)
        XCTAssertEqual(owed.count, AppConfig.statusLogLimit, "older ones would be pruned on arrival")
        XCTAssertEqual(owed.first?.message, "\(AppConfig.statusLogLimit + 4)", "newest first")
    }

    /// Hand-written Codable (invariant 5): old files read as logged, and a logged entry writes as before.
    func testTheMarkIsOptionalOnDisk() throws {
        let old = Data(#"[{"emoji":"☕️","message":"coffee","isCelebration":false,"at":"2026-01-01T00:00:00Z","fromMe":true}]"#.utf8)
        let decoded = try JSONDecoder.shared.decode([StatusHistoryEntry].self, from: old)
        XCTAssertEqual(decoded.first?.unlogged, false)
        let written = try JSONEncoder.shared.encode(decoded)
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("unlogged"))
        var owed = decoded[0]
        owed.unlogged = true
        let roundTrip = try JSONDecoder.shared.decode(StatusHistoryEntry.self, from: JSONEncoder.shared.encode(owed))
        XCTAssertTrue(roundTrip.unlogged)
    }

    /// An earlier status's log is the same record its own publish would have
    /// written: same name, same fields, so a resend overwrites itself.
    func testAnEarlierStatusesLogRecordIsTheOneItsPublishWouldWrite() {
        let coffee = Fixtures.status("☕️", "coffee", at: Fixtures.t0)
        let fromEntry = CloudSync.statusLogRecord(StatusHistoryEntry(coffee, fromMe: true, unlogged: true),
                                                  role: .owner, zone: Fixtures.zone)
        let fromPayload = CloudSync.statusLogRecord(coffee, role: .owner, zone: Fixtures.zone)
        XCTAssertEqual(fromEntry.recordID, fromPayload.recordID)
        XCTAssertEqual(fromEntry.encryptedValues[CloudSync.Field.message] as? String, "coffee")
        XCTAssertEqual(fromEntry[CloudSync.Field.updatedAt] as? Date, Fixtures.t0)
    }
}
