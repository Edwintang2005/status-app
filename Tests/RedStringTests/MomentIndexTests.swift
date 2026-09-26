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

    /// A full-zone fetch is the one time "not returned" means "not on the
    /// server": own sends marked uploaded that it didn't return go back in the
    /// retry queue, unless their media is gone (nothing left to send).
    func testRequeueMissingUploadsAfterFullFetch() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("kept", fromMe: true, uploaded: true),
                      Fixtures.moment("lost", fromMe: true, uploaded: true),
                      Fixtures.moment("lostNoMedia", fromMe: true, uploaded: true),
                      Fixtures.moment("pending", fromMe: true, uploaded: false),
                      Fixtures.moment("theirs", fromMe: false)])

        let requeued = index.requeueMissingUploads(delivered: ["kept"]) { $0.id != "lostNoMedia" }

        XCTAssertEqual(requeued.map(\.id), ["lost"])
        let byID = Dictionary(uniqueKeysWithValues: index.load().map { ($0.id, $0) })
        XCTAssertEqual(byID["lost"]?.uploaded, false)
        XCTAssertEqual(byID["kept"]?.uploaded, true)
        XCTAssertEqual(byID["lostNoMedia"]?.uploaded, true, "no media left to send; leave it be")
        XCTAssertEqual(byID["pending"]?.uploaded, false)
        XCTAssertEqual(byID["theirs"]?.uploaded, true, "the partner's moments are never ours to send")
        XCTAssertEqual(index.load().count, 5)
    }

    func testEncryptedTextSurvivesUnreadableRedelivery() {
        let (index, _) = makeIndex()
        var sent = Fixtures.moment("v1", kind: .voice)
        sent.caption = "for you"
        sent.waveform = [0.2, 0.8]
        index.insert([sent])

        // A copy rebuilt from a record whose encrypted fields came back empty.
        var blank = Fixtures.moment("v1", kind: .voice)
        blank.senderName = ""
        let merged = index.insert([blank]).first!
        XCTAssertEqual(merged.caption, "for you")
        XCTAssertEqual(merged.senderName, "Sam")
        XCTAssertEqual(merged.waveform, [0.2, 0.8])
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

    func testRetainPendingUploadsKeepsOnlyUnsentOwnMoments() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("p1"),
                      Fixtures.moment("sent", fromMe: true, uploaded: true),
                      Fixtures.moment("pending", fromMe: true, uploaded: false)])
        let kept = index.retainPendingUploads()
        XCTAssertEqual(kept.map(\.id), ["pending"])
        XCTAssertEqual(index.load().map(\.id), ["pending"])
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

    // MARK: Cap, clocks, unreadable file

    func testCapNeverDropsAPendingSend() {
        let (index, _) = makeIndex()
        let pending = Fixtures.moment("pending", at: Fixtures.date(-10_000), fromMe: true, uploaded: false)
        let flood = (0..<AppConfig.momentHistoryLimit).map { Fixtures.moment("p\($0)", at: Fixtures.date(Double($0))) }
        index.insert([pending] + flood)
        let saved = index.load()
        XCTAssertTrue(saved.contains { $0.id == "pending" }, "no cloud copy: leaving the index loses it")
        XCTAssertEqual(saved.count, AppConfig.momentHistoryLimit + 1)
    }

    func testFutureDatesAreHealed() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("ahead", at: Date().addingTimeInterval(86_400))])
        XCTAssertFalse(TrustedTime.isFuture(index.load()[0].sentAt))
    }

    /// Before first unlock (or on an I/O error) the file can't be read; the
    /// delta must not replace the history, nor callers prune against it.
    func testUnreadableFileIsLeftUntouched() throws {
        let (index, url) = makeIndex()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        index.insert([Fixtures.moment("p1")])
        XCTAssertTrue(index.readFailed)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "nothing was written over it")
        XCTAssertEqual(corruptHits, 0, "unreadable isn't corrupt: no sidecar, no resync")
    }
}
