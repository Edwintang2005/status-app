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

    /// After a fresh start "not returned" is mostly "cleared": a second device's
    /// old index must not re-send the cleared history.
    func testRequeueLeavesSendsFromBeforeAFreshStartAlone() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("cleared", at: Fixtures.date(100), fromMe: true),
                      Fixtures.moment("lostSince", at: Fixtures.date(2_000), fromMe: true)])
        let requeued = index.requeueMissingUploads(delivered: [], hasMedia: { _ in true },
                                                   clearedBefore: Fixtures.date(1_000))
        XCTAssertEqual(requeued.map(\.id), ["lostSince"])
    }

    func testRemovingManyAtOnce() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("a"), Fixtures.moment("b", at: Fixtures.date(1)), Fixtures.moment("c", at: Fixtures.date(2))])
        index.remove(ids: ["a", "c", "missing"])
        XCTAssertEqual(index.load().map(\.id), ["b"])
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
        let (index, url) = makeIndex()
        index.insert([Fixtures.moment("o1", fromMe: true, uploaded: false)])
        XCTAssertFalse(index.load()[0].uploaded)
        XCTAssertTrue(index.markUploaded(ids: ["o1"])[0].uploaded)
        index.remove(id: "o1")
        XCTAssertEqual(index.load(), [])

        let identity = FileIdentity(url)
        XCTAssertNotNil(identity)
        index.remove(id: "absent")
        XCTAssertEqual(FileIdentity(url), identity, "removing nothing must not rewrite the file")
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

    /// A favourite is local only: it survives the copy iCloud sends again, and the cap.
    func testAFavouriteIsKeptThroughRedeliveryAndTheCap() throws {
        let (index, _) = makeIndex()
        let old = Fixtures.moment("old", at: Fixtures.date(-10_000))
        index.insert([old])
        let starred = index.setFavourite(id: "old", true, at: Fixtures.date(5.7))
        XCTAssertEqual(starred.first?.favouritedAt, Fixtures.date(5), "whole seconds")

        index.insert([Fixtures.moment("old", at: Fixtures.date(-10_000))])
        XCTAssertTrue(try XCTUnwrap(index.load().first).isFavourite, "a fetched copy carries none")

        let flood = (0..<AppConfig.momentHistoryLimit).map { Fixtures.moment("p\($0)", at: Fixtures.date(Double($0))) }
        index.insert(flood)
        XCTAssertTrue(index.load().contains { $0.id == "old" }, "starring one is asking to keep it")

        index.setFavourite(id: "old", false)
        index.insert([Fixtures.moment("new", at: Fixtures.date(1_000_000))])
        XCTAssertFalse(index.load().contains { $0.id == "old" }, "unstarred, the cap applies again")
    }

    /// Unstarred past the cap, it stays until the next arrival — a page turn's
    /// seen-write included — so a slip can be starred back.
    func testUnstarringPastTheCapCanBeUndone() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("old", at: Fixtures.date(-10_000))])
        index.setFavourite(id: "old", true)
        index.insert((0..<AppConfig.momentHistoryLimit).map { Fixtures.moment("p\($0)", at: Fixtures.date(Double($0))) })
        XCTAssertTrue(index.setFavourite(id: "old", false).contains { $0.id == "old" })
        XCTAssertTrue(index.markSeen(ids: ["p3"]).contains { $0.id == "old" }, "a page turn doesn't trim")
        XCTAssertTrue(index.setFavourite(id: "old", true).contains { $0.id == "old" && $0.isFavourite })
        index.setFavourite(id: "old", false)
        index.insert([Fixtures.moment("newer", at: Fixtures.date(1_000_000))])
        XCTAssertFalse(index.load().contains { $0.id == "old" }, "the next arrival trims it")
    }

    /// The cap raised by an update: the index is swept once, and stops short until it is.
    func testAnIndexFilledUnderASmallerCapIsSweptOnce() {
        XCTAssertEqual(HistoryCoverage.after(HistoryCoverage.owed, finished: false, limit: 5_000), HistoryCoverage.owed,
                       "a fetch that landed on another lineage passes finished: false")
        XCTAssertTrue(HistoryCoverage.needsSweep(nil), "kept before this was recorded")
        XCTAssertTrue(HistoryCoverage.needsSweep(500, limit: 5_000))
        XCTAssertFalse(HistoryCoverage.needsSweep(HistoryCoverage.owed), "already under way")
        XCTAssertFalse(HistoryCoverage.needsSweep(5_000, limit: 5_000))
        XCTAssertEqual(HistoryCoverage.after(HistoryCoverage.owed, finished: false, limit: 5_000), HistoryCoverage.owed)
        XCTAssertEqual(HistoryCoverage.after(HistoryCoverage.owed, finished: true, limit: 5_000), 5_000)
        XCTAssertEqual(HistoryCoverage.after(500, finished: true, limit: 5_000), 500, "only an owed sweep completes")
        XCTAssertFalse(HistoryCoverage.isComplete(HistoryCoverage.owed, limit: 5_000))
        XCTAssertTrue(HistoryCoverage.isComplete(5_000, limit: 5_000))
    }

    func testClearingTheTokensOwesASweep() {
        let store = SharedStore(defaults: temporaryDefaults())
        store.historyCoverage = AppConfig.momentHistoryLimit
        store.clearChangeTokens()
        XCTAssertEqual(store.historyCoverage, HistoryCoverage.owed)
    }

    func testFavouritesSurviveTheFileAndOlderEntriesDecode() throws {
        let (index, url) = makeIndex()
        index.insert([Fixtures.moment("a"), Fixtures.moment("b", at: Fixtures.date(1))])
        index.setFavourite(id: "a", true)
        let reread = MomentIndex(fileURL: url, onCorrupt: {}).load()
        XCTAssertEqual(reread.filter(\.isFavourite).map(\.id), ["a"])
        let legacy = Data(#"{"id":"x","kind":"photo","caption":"","senderName":"Sam","sentAt":"2026-01-01T00:00:00Z","fromMe":false}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertFalse(try decoder.decode(Moment.self, from: legacy).isFavourite, "an older build's entry")
    }

    func testFutureDatesAreHealed() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("ahead", at: Date().addingTimeInterval(3 * 86_400))])
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

    // MARK: Caption edits

    func testAnEditIsOwedUntilItsOwnWordsArePublished() throws {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("mine", fromMe: true), Fixtures.moment("theirs")])
        XCTAssertNil(index.editCaption(id: "theirs", to: "nope"), "only our own moments")
        let edited = try XCTUnwrap(index.editCaption(id: "mine", to: "first", at: Fixtures.date(5)))
        XCTAssertFalse(edited.captionPublished)
        XCTAssertEqual(edited.captionEditedAt, Fixtures.date(5))
        index.editCaption(id: "mine", to: "second")
        index.markCaptionPublished(id: "mine", caption: "first")
        XCTAssertEqual(index.load().first { $0.id == "mine" }?.captionPublished, false, "edited again meanwhile")
        index.markCaptionPublished(id: "mine", caption: "second")
        XCTAssertEqual(index.load().first { $0.id == "mine" }?.captionPublished, true)
    }

    /// The old copy fetched before the edit lands mustn't undo it.
    func testAPendingEditBeatsTheServerCopy() {
        let (index, _) = makeIndex()
        index.insert([Fixtures.moment("mine", fromMe: true)])
        index.editCaption(id: "mine", to: "edited")
        var stale = Fixtures.moment("mine", fromMe: true)
        stale.caption = "original"
        index.insert([stale])
        let kept = index.load().first { $0.id == "mine" }
        XCTAssertEqual(kept?.caption, "edited")
        XCTAssertEqual(kept?.captionPublished, false)
    }

    /// A readable copy with no caption is a removed caption; one with no
    /// encrypted fields at all couldn't be read, and keeps the words.
    func testAClearedCaptionArrivesButAnUnreadableCopyKeepsTheWords() {
        let (index, _) = makeIndex()
        var original = Fixtures.moment("m1")
        original.caption = "hello"
        index.insert([original])
        var unreadable = Fixtures.moment("m1")
        unreadable.caption = ""
        unreadable.senderName = ""
        index.insert([unreadable])
        XCTAssertEqual(index.load().first?.caption, "hello")
        XCTAssertNil(index.load().first?.captionEditedAt)
        var cleared = Fixtures.moment("m1")
        cleared.caption = ""
        index.insert([cleared])
        XCTAssertEqual(index.load().first?.caption, "")
        XCTAssertNotNil(index.load().first?.captionEditedAt, "marked edited")
    }
}

/// Captions travel as one line (`Moment.caption(from:)`).
final class MomentCaptionTests: XCTestCase {
    func testACaptionIsOneTrimmedLine() {
        XCTAssertEqual(Moment.caption(from: "  sunset\nat bondi \r\n"), "sunset at bondi")
        XCTAssertEqual(Moment.caption(from: "a\n\n\nb"), "a b")
        XCTAssertEqual(Moment.caption(from: "\n \n"), "")
        XCTAssertEqual(Moment.caption(from: String(repeating: "x", count: AppConfig.captionMaxLength + 5)).count,
                       AppConfig.captionMaxLength)
    }
}

/// Diagnostics' test padding (`MomentIndex.padding`): local, seen, and out of every recap's reach.
final class HistoryPaddingTests: XCTestCase {
    func testPaddingIsSeenOldAndRecognisable() {
        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        let padding = MomentIndex.padding(count: 50, before: oldest)
        XCTAssertEqual(padding.count, 50)
        XCTAssertEqual(Set(padding.map(\.id)).count, 50)
        XCTAssertTrue(padding.allSatisfy { MomentIndex.isPadding($0.id) && $0.seen && !$0.fromMe })
        let twenty20 = Date(timeIntervalSince1970: 1_577_836_800)
        XCTAssertTrue(padding.allSatisfy { $0.sentAt < twenty20 }, "before any recap period")
        XCTAssertTrue(padding.contains { $0.isVoice && !$0.waveform.isEmpty }, "memos too, for a realistic size")
        XCTAssertTrue(MomentIndex.padding(count: 0, before: nil).isEmpty)
        XCTAssertFalse(MomentIndex.isPadding("ABC-123"))
    }

    func testPaddingFillsToTheCapAndIsMeasured() throws {
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert([Fixtures.moment("real")])
        index.insert(MomentIndex.padding(count: AppConfig.momentHistoryLimit - 1, before: Fixtures.t0))
        XCTAssertEqual(index.load().count, AppConfig.momentHistoryLimit)
        XCTAssertEqual(index.load().first?.id, "real", "padding sits behind the real history")
        let measured = try XCTUnwrap(index.measure())
        XCTAssertEqual(measured.count, AppConfig.momentHistoryLimit)
        XCTAssertGreaterThan(measured.bytes, 0)
        print("PADDED INDEX: \(measured.bytes / 1024) KB, decode \(Int(measured.decode * 1000)) ms, encode \(Int(measured.encode * 1000)) ms")
    }
}
