import XCTest

/// Status history dedups by `(fromMe, whole-second updatedAt)` across its two
/// feeds (CLAUDE.md invariant 14) and mirrors cloud deletions.
final class StatusHistoryLogTests: XCTestCase {
    private func makeLog() -> (StatusHistoryLog, URL) {
        let url = temporaryFile("status-history.json")
        return (StatusHistoryLog(fileURL: url), url)
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
        log.record(Fixtures.status(), fromMe: true)
        XCTAssertEqual(log.load().count, 1)
    }

    func testLegacyDuplicatesSelfHeal() throws {
        let (log, url) = makeLog()
        // Two copies of one entry, as written before dedup dates were whole seconds.
        let entry = StatusHistoryEntry(Fixtures.status(), fromMe: true)
        try JSONEncoder.shared.encode([entry, entry]).write(to: url)
        XCTAssertEqual(log.load().count, 1)
    }
}
