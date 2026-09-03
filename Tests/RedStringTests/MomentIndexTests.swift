import XCTest

/// The history index: ordering, sticky local-only fields (CLAUDE.md invariant
/// 13), receipts that never un-see, and the corrupt-file sidecar (invariant 15).
final class MomentIndexTests: XCTestCase {
    private var corruptHits = 0

    private func makeIndex() -> (MomentIndex, URL) {
        let url = temporaryFile("moments-index.json")
        return (MomentIndex(fileURL: url, onCorrupt: { [self] in corruptHits += 1 }), url)
    }

    func testInsertSortsNewestFirstAndReplacesByID() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("old", at: Fixtures.date(-100)),
                      Fixtures.moment("new", at: Fixtures.t0)])
        XCTAssertEqual(index.load().map(\.id), ["new", "old"])

        var edited = Fixtures.moment("old", at: Fixtures.date(-100))
        edited.caption = "edited"
        let all = index.insert([edited])
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(index.load().last?.caption, "edited")
    }

    func testLocalOnlyFieldsSurviveRedelivery() {
        let (index, _) = makeIndex()
        var own = Fixtures.moment("o1", fromMe: true, uploaded: true)
        own.seenAt = Fixtures.date(-30)
        own.seenByPartnerAt = Fixtures.date(-10)
        index.insert([own])

        // What a CloudKit re-delivery looks like: no local-only state at all.
        var rebuilt = Fixtures.moment("o1", fromMe: true, seen: false, uploaded: false)
        rebuilt.seenAt = nil
        rebuilt.seenByPartnerAt = nil
        let merged = index.insert([rebuilt]).first!
        XCTAssertTrue(merged.seen)
        XCTAssertEqual(merged.seenAt, Fixtures.date(-30))
        XCTAssertEqual(merged.seenByPartnerAt, Fixtures.date(-10))
        XCTAssertTrue(merged.uploaded)
    }

    func testMarkSeenStampsOnce() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("p1")])
        let first = index.markSeen(ids: ["p1"]).first!
        XCTAssertTrue(first.seen)
        let stamp = first.seenAt
        XCTAssertNotNil(stamp)

        let again = index.markSeen(ids: ["p1", "missing"]).first!
        XCTAssertEqual(again.seenAt, stamp, "re-marking must not move the time")
    }

    func testPartnerReceiptsApplyOnlyToOwnMomentsAndNeverUnsee() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("o1", fromMe: true), Fixtures.moment("p1")])
        index.applyPartnerReceipts(["o1": Fixtures.date(5), "p1": Fixtures.date(5)])
        var all = index.load()
        XCTAssertEqual(all.first { $0.id == "o1" }?.seenByPartnerAt, Fixtures.date(5))
        XCTAssertNil(all.first { $0.id == "p1" }?.seenByPartnerAt, "receipts describe our sends only")

        index.applyPartnerReceipts([:])
        all = index.load()
        XCTAssertEqual(all.first { $0.id == "o1" }?.seenByPartnerAt, Fixtures.date(5),
                       "a shrunken or retracted map must not un-see")
    }

    func testMarkUploadedAndRemove() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("o1", fromMe: true, uploaded: false)])
        XCTAssertFalse(index.load()[0].uploaded)
        XCTAssertTrue(index.markUploaded(ids: ["o1"])[0].uploaded)
        index.remove(id: "o1")
        XCTAssertEqual(index.load(), [])
        XCTAssertEqual(index.knownIDs(), [])
    }

    func testCapKeepsTheNewest() {
        let (index, _) = makeIndex()
        let extra = 5
        let moments = (0..<(AppConfig.momentHistoryLimit + extra)).map {
            Fixtures.moment("m\($0)", at: Fixtures.date(Double($0)))
        }
        index.insert(moments)
        let kept = index.load()
        XCTAssertEqual(kept.count, AppConfig.momentHistoryLimit)
        XCTAssertEqual(kept.first?.id, "m\(AppConfig.momentHistoryLimit + extra - 1)")
        XCTAssertEqual(kept.last?.id, "m\(extra)")
    }

    func testCorruptFileIsPreservedNotOverwritten() throws {
        let (index, url) = makeIndex()
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(index.load(), [])
        XCTAssertEqual(corruptHits, 1, "tokens are cleared so CloudKit rebuilds the index")
        let sidecar = url.appendingPathExtension("corrupt")
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("not json".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        index.insert([Fixtures.moment("p1")])
        XCTAssertEqual(index.load().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "the sidecar stays")
    }

    func testClearRemovesFile() {
        let (index, url) = makeIndex()
        index.insert([Fixtures.moment("p1")])
        index.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(index.load(), [])
    }
}
