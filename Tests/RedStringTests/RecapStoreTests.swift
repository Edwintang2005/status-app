import XCTest

/// Finished recaps (`RecapStore`): one per period, replaced by the next, erased with the history.
final class RecapStoreTests: XCTestCase {
    private func store() -> RecapStore {
        RecapStore(directory: temporaryFile("Recaps").deletingLastPathComponent().appendingPathComponent("Recaps"))
    }

    private func staged(_ bytes: String) throws -> URL {
        let url = temporaryFile("staged-\(UUID().uuidString).mp4")
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func testAKeptRecapIsFoundAgainAndReplacedByTheNext() throws {
        let store = store()
        XCTAssertNil(store.saved(for: .year(2026)))
        let first = try store.keep(staged("first"), for: .year(2026))
        XCTAssertEqual(first.url.lastPathComponent, "\(AppConfig.appName) 2026.mp4")
        XCTAssertEqual(store.saved(for: .year(2026))?.url, first.url)
        XCTAssertNil(store.saved(for: .year(2025)), "each period its own")

        _ = try store.keep(staged("second"), for: .year(2026))
        XCTAssertEqual(try String(contentsOf: first.url, encoding: .utf8), "second")
        XCTAssertEqual(try first.url.deletingLastPathComponent()
                        .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "the folder stays out of backups: remade from the history any time")
    }

    /// Only the year on offer is reachable: keeping a newer one drops the older,
    /// never Diagnostics' twelve-month video.
    func testANewYearReplacesTheLast() throws {
        let store = store()
        _ = try store.keep(staged("2026"), for: .year(2026))
        _ = try store.keep(staged("twelve"), for: .lastTwelveMonths)
        _ = try store.keep(staged("2027"), for: .year(2027))
        XCTAssertNil(store.saved(for: .year(2026)))
        XCTAssertNotNil(store.saved(for: .year(2027)))
        XCTAssertNotNil(store.saved(for: .lastTwelveMonths))
        XCTAssertEqual(store.size(), "2027".utf8.count + "twelve".utf8.count)

        store.removeYears(except: 2028)
        XCTAssertNil(store.saved(for: .year(2027)), "unreachable once 2028 unwraps")
        XCTAssertNotNil(store.saved(for: .lastTwelveMonths))
    }

    func testRemoveAllErasesEveryRecap() throws {
        let store = store()
        _ = try store.keep(staged("a"), for: .year(2026))
        _ = try store.keep(staged("b"), for: .lastTwelveMonths)
        store.removeAll()
        XCTAssertNil(store.saved(for: .year(2026)))
        XCTAssertNil(store.saved(for: .lastTwelveMonths))
    }
}
