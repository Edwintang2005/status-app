import XCTest

/// The memories archive reads the whole zone and this phone together: the zone
/// past the index's cap, the phone for unsent moments and pre-cloud statuses.
final class ArchiveContentsTests: XCTestCase {
    private func entry(_ emoji: String, at seconds: TimeInterval, fromMe: Bool = false) -> StatusHistoryEntry {
        StatusHistoryEntry(emoji: emoji, message: "", isCelebration: false,
                           at: Fixtures.date(seconds), fromMe: fromMe)
    }

    func testMergesBothSourcesOldestFirst() {
        let zone = ArchiveContents.Zone(
            moments: [Fixtures.moment("b", at: Fixtures.date(20)), Fixtures.moment("a", at: Fixtures.date(10))],
            statuses: [entry("🌧️", at: 30)],
            unreadable: 0)
        let unsent = Fixtures.moment("c", at: Fixtures.date(30), fromMe: true, uploaded: false)
        let merged = ArchiveContents.merged(zone: zone,
                                            localMoments: [unsent, Fixtures.moment("b", at: Fixtures.date(20))],
                                            localStatuses: [entry("☀️", at: 5, fromMe: true)],
                                            anniversary: nil, hidden: [])

        XCTAssertEqual(merged.moments.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(merged.statuses.map(\.emoji), ["☀️", "🌧️"])
        XCTAssertTrue(merged.isComplete)
    }

    /// The zone's copy of a record this phone already filed may have come back blank.
    func testLocalCopiesWin() {
        var local = Fixtures.moment("a")
        local.caption = "the beach"
        let zone = ArchiveContents.Zone(moments: [Fixtures.moment("a")],
                                        statuses: [entry("💭", at: 10)], unreadable: 0)
        let merged = ArchiveContents.merged(zone: zone, localMoments: [local],
                                            localStatuses: [entry("🥰", at: 10)],
                                            anniversary: nil, hidden: [])

        XCTAssertEqual(merged.moments.map(\.caption), ["the beach"])
        XCTAssertEqual(merged.statuses.map(\.emoji), ["🥰"], "deduped by (fromMe, at), like the log")
    }

    func testReportedMomentsStayOut() {
        let zone = ArchiveContents.Zone(moments: [Fixtures.moment("reported")], statuses: [], unreadable: 0)
        let merged = ArchiveContents.merged(zone: zone, localMoments: [Fixtures.moment("reported"), Fixtures.moment("kept")],
                                            localStatuses: [], anniversary: nil, hidden: ["reported"])
        XCTAssertEqual(merged.moments.map(\.id), ["kept"])
    }

    /// Anything short of the whole zone must not be the last copy before a delete.
    func testCompletenessIsTold() {
        let local = ArchiveContents.merged(zone: nil, localMoments: [Fixtures.moment("a")],
                                           localStatuses: [], anniversary: nil, hidden: [])
        XCTAssertFalse(local.includesZone)
        XCTAssertFalse(local.isComplete)

        let held = ArchiveContents.merged(zone: .init(moments: [], statuses: [], unreadable: 2),
                                          localMoments: [Fixtures.moment("a")],
                                          localStatuses: [], anniversary: nil, hidden: [])
        XCTAssertTrue(held.includesZone)
        XCTAssertFalse(held.isComplete)

        let empty = ArchiveContents.merged(zone: .init(moments: [], statuses: [], unreadable: 0),
                                           localMoments: [], localStatuses: [], anniversary: nil, hidden: [])
        XCTAssertTrue(empty.isEmpty)
    }
}
