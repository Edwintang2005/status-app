import XCTest

/// The library grid's thumbnail batching (#22): one CloudKit request per up to
/// 50 tiles, at most two out at once, and a tile scrolled away never fetched.
final class ThumbnailBatchQueueTests: XCTestCase {
    func testBatchesCapAtTheLimitNewestRequestFirst() {
        var queue = ThumbnailBatchQueue()
        for index in 0..<120 { queue.request("m\(index)") }

        let first = queue.nextBatch()
        XCTAssertEqual(first?.count, ThumbnailBatchQueue.batchLimit)
        XCTAssertEqual(first?.first, "m119", "mid-flick, the tile on screen now asked last")
        let second = queue.nextBatch()
        XCTAssertEqual(second?.count, ThumbnailBatchQueue.batchLimit)
        XCTAssertNil(queue.nextBatch(), "two batches out is the ceiling")
        XCTAssertEqual(queue.waiting.count, 20)

        queue.finish(first ?? [])
        XCTAssertEqual(queue.nextBatch()?.count, 20, "a finished batch frees a slot for the rest")
    }

    func testDuplicatesAndInFlightIDsAreNotQueuedTwice() {
        var queue = ThumbnailBatchQueue()
        XCTAssertTrue(queue.request("a"))
        XCTAssertFalse(queue.request("a"))
        let batch = queue.nextBatch()
        XCTAssertEqual(batch, ["a"])
        XCTAssertFalse(queue.request("a"), "already on its way")
        queue.finish(batch ?? [])
        XCTAssertTrue(queue.request("a"), "asked again once that batch is back (it failed, say)")
    }

    func testWithdrawnTilesNeverLeave() {
        var queue = ThumbnailBatchQueue()
        queue.request("a")
        queue.request("b")
        queue.withdraw("a")
        XCTAssertEqual(queue.nextBatch(), ["b"])
        XCTAssertNil(queue.nextBatch())
    }
}

@MainActor
final class ThumbnailFetcherTests: XCTestCase {
    /// Records each batch and how many were out at once; `missing` never arrives.
    @MainActor private final class Recorder {
        var batches: [[String]] = []
        var inFlight = 0
        var peak = 0
        var missing: Set<String> = []
    }

    private func fetcher(_ recorder: Recorder, delay: Duration = .milliseconds(20)) -> ThumbnailFetcher {
        ThumbnailFetcher(coalesceDelay: .milliseconds(30)) { moments in
            recorder.batches.append(moments.map(\.id))
            recorder.inFlight += 1
            recorder.peak = max(recorder.peak, recorder.inFlight)
            try? await Task.sleep(for: delay)
            recorder.inFlight -= 1
            return Set(moments.map(\.id)).subtracting(recorder.missing)
        }
    }

    func testCoalescesAFlickIntoBoundedBatches() async {
        let recorder = Recorder()
        recorder.missing = ["m7"]
        let fetcher = fetcher(recorder)
        let moments = (0..<120).map { Fixtures.moment("m\($0)") }

        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for moment in moments {
                group.addTask { @MainActor in (moment.id, await fetcher.thumbnail(for: moment)) }
            }
            var results: [String: Bool] = [:]
            for await (id, fetched) in group { results[id] = fetched }
            return results
        }

        XCTAssertEqual(results.count, 120)
        XCTAssertEqual(results["m7"], false, "the one the batch didn't bring")
        XCTAssertEqual(results.values.filter { $0 }.count, 119)
        XCTAssertEqual(recorder.batches.flatMap { $0 }.count, 120, "each tile fetched once")
        XCTAssertTrue(recorder.batches.allSatisfy { $0.count <= ThumbnailBatchQueue.batchLimit })
        XCTAssertLessThanOrEqual(recorder.batches.count, 4, "batched, not a request per tile")
        XCTAssertLessThanOrEqual(recorder.peak, ThumbnailBatchQueue.maxInFlight)
    }

    func testTwoTilesForOneMomentShareOneFetch() async {
        let recorder = Recorder()
        let fetcher = fetcher(recorder)
        let moment = Fixtures.moment("same")
        async let first = fetcher.thumbnail(for: moment)
        async let second = fetcher.thumbnail(for: moment)
        let (a, b) = await (first, second)
        XCTAssertTrue(a && b)
        XCTAssertEqual(recorder.batches, [["same"]])
    }

    func testACancelledTileIsWithdrawnAndAnsweredAtOnce() async {
        let recorder = Recorder()
        let fetcher = fetcher(recorder)
        let gone = Task { @MainActor in await fetcher.thumbnail(for: Fixtures.moment("gone")) }
        gone.cancel()
        let kept = await fetcher.thumbnail(for: Fixtures.moment("kept"))
        let goneResult = await gone.value
        XCTAssertFalse(goneResult)
        XCTAssertTrue(kept)
        XCTAssertEqual(recorder.batches, [["kept"]], "scrolled away before its batch left: never asked for")
    }
}
