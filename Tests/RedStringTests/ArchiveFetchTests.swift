import CloudKit
import XCTest

/// The memories archive's downloads and what they allow before a delete
/// (redesign A): chunked, retried smaller, failures sorted, gone asked about.
final class ArchiveFetchTests: XCTestCase {
    private func moments(_ count: Int) -> [Moment] {
        (0..<count).map { Fixtures.moment("m\($0)", at: Fixtures.date(Double($0))) }
    }

    private func fetcher(_ backend: FakeBackend, landed: @escaping @Sendable (Moment) -> Bool = { _ in false })
        -> ArchiveFetcher {
        ArchiveFetcher(fetch: { try await backend.fetchArchiveMedia($0, to: [:]) },
                       lanes: 1, pause: { _ in }, landed: landed)
    }

    // MARK: The gate

    func testTheGateAsksOnlyWhenNothingElseIsMissing() {
        XCTAssertEqual(ArchiveGate(contentsComplete: true, unrecovered: 0, unsupported: 0, gone: 0), .proceed)
        XCTAssertEqual(ArchiveGate(contentsComplete: true, unrecovered: 0, unsupported: 0, gone: 3), .confirmGone(3))
        XCTAssertEqual(ArchiveGate(contentsComplete: true, unrecovered: 0, unsupported: 1, gone: 3), .updateFirst)
        XCTAssertEqual(ArchiveGate(contentsComplete: true, unrecovered: 1, unsupported: 1, gone: 3), .retry,
                       "a failed download may just need signal: tried again before anything else")
        XCTAssertEqual(ArchiveGate(contentsComplete: false, unrecovered: 0, unsupported: 0, gone: 0), .retry,
                       "the zone not read whole")
    }

    /// A by-ID "not found" for a record the zone's own listing just returned is
    /// a failed fetch — never "gone", which a delete would act on (APP-1's audit).
    func testNotFoundIsGoneOnlyWhenTheListingAgrees() {
        let listed = Fixtures.moment("listed")
        let contents = ArchiveContents.merged(zone: .init(moments: [listed], statuses: [], unreadable: 0),
                                              localMoments: [Fixtures.moment("local")], localStatuses: [],
                                              anniversary: nil, hidden: [])
        XCTAssertFalse(contents.isGone(.notFound, momentID: "listed"))
        XCTAssertTrue(contents.isGone(.notFound, momentID: "local"))
        XCTAssertTrue(contents.isGone(.gone, momentID: "listed"), "the record came back without its file")
        XCTAssertFalse(contents.isGone(.failed(retryAt: nil), momentID: "local"))
        XCTAssertFalse(contents.isGone(nil, momentID: "local"))
    }

    func testNotFoundIsFinal() async {
        let backend = FakeBackend()
        backend.archiveAnswer = { chunk in Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, .notFound) }) }
        let results = await fetcher(backend).run(moments(3))
        XCTAssertEqual(backend.archiveChunks.count, 1, "not asked again")
        XCTAssertTrue(results.values.allSatisfy { $0 == .notFound })
    }

    // MARK: The fetcher

    func testItAsksInChunks() async {
        let backend = FakeBackend()
        let results = await fetcher(backend).run(moments(25))

        XCTAssertEqual(backend.archiveChunks.map(\.count), [10, 10, 5])
        XCTAssertEqual(results.count, 25)
        XCTAssertTrue(results.values.allSatisfy { $0 == .saved })
    }

    /// A failed chunk is asked for again, smaller; what's gone isn't asked again.
    func testFailuresAreRetriedSmallerAndGoneIsFinal() async {
        let backend = FakeBackend()
        let attempts = Counter()
        backend.archiveAnswer = { chunk in
            let first = attempts.next() == 1
            return Dictionary(uniqueKeysWithValues: chunk.map { moment in
                (moment.id, moment.id == "m0" ? .gone : first ? .failed(retryAt: nil) : .saved)
            })
        }
        let results = await fetcher(backend).run(moments(7))

        XCTAssertEqual(backend.archiveChunks.map(\.count), [7, 5, 1], "the six that failed, in chunks of five")
        XCTAssertFalse(backend.archiveChunks.dropFirst().joined().contains("m0"))
        XCTAssertEqual(results["m0"], .gone)
        XCTAssertEqual(results.values.filter { $0 == .saved }.count, 6)
    }

    /// A chunk that throws (offline, throttled) fails each of its moments, and the
    /// retry waits as long as iCloud asked, capped at a minute.
    func testAThrottledChunkWaitsBeforeItsRetry() async {
        let backend = FakeBackend()
        let attempts = Counter()
        backend.archiveAnswer = { chunk in
            if attempts.next() == 1 { throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0]) }
            return Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, .saved) })
        }
        let waited = Recorder<TimeInterval>()
        var fetcher = fetcher(backend)
        fetcher.pause = { waited.append($0) }
        let results = await fetcher.run(moments(3))

        XCTAssertEqual(results.values.filter { $0 == .saved }.count, 3)
        XCTAssertEqual(waited.values.count, 1)
        XCTAssertEqual(waited.values.first ?? 0, 30, accuracy: 2)
    }

    /// Failed twice, it stays failed — unless its file landed late, after the deadline gave up on it.
    func testAFileThatLandedLateCountsAsSaved() async {
        let backend = FakeBackend()
        backend.archiveAnswer = { chunk in Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, .failed(retryAt: nil)) }) }
        let results = await fetcher(backend, landed: { $0.id == "m1" }).run(moments(2))

        XCTAssertEqual(results["m0"], .failed(retryAt: nil))
        XCTAssertEqual(results["m1"], .saved)
    }

    /// A record the answer left out wasn't fetched: it's tried again, not taken as saved.
    func testAMomentTheAnswerLeftOutIsRetried() async {
        let backend = FakeBackend()
        let attempts = Counter()
        backend.archiveAnswer = { chunk in
            attempts.next() == 1 ? [:] : Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, .saved) })
        }
        let results = await fetcher(backend).run(moments(2))
        XCTAssertEqual(results.values.filter { $0 == .saved }.count, 2)
        XCTAssertEqual(backend.archiveChunks.count, 2)
    }
}

/// Counts calls across concurrent tasks.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}
