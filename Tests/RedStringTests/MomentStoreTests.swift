import XCTest

/// "Clear downloaded media" on a temporary folder: full files go, thumbnails
/// and kept ids stay, and a file written moments ago is spared.
final class MomentStoreTests: XCTestCase {
    private var directory: URL!
    private var store: MomentStore!

    override func setUp() {
        directory = temporaryFile("Moments")
        store = MomentStore(directory: directory)
    }

    private func write(_ name: String, bytes: Int = 10, age: TimeInterval = 3_600) throws {
        let url = try XCTUnwrap(store.directory).appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
    }

    private var remaining: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    func testClearsFullMediaButKeepsThumbnailsAndKeptIDs() throws {
        try write("old.jpg", bytes: 100)
        try write("old-thumb.jpg")
        try write("memo.m4a", bytes: 50)
        try write("unsent.jpg", bytes: 70)
        try write("unsent-thumb.jpg")

        XCTAssertEqual(store.downloadedSize(keeping: ["unsent"]), 150)
        XCTAssertEqual(store.clearDownloaded(keeping: ["unsent"]), 150)
        XCTAssertEqual(remaining, ["old-thumb.jpg", "unsent.jpg", "unsent-thumb.jpg"])
        XCTAssertEqual(store.downloadedSize(keeping: ["unsent"]), 0)
    }

    /// Another process may have just filed a delivery, or a send not yet in the index.
    func testSparesFilesInsideTheGraceWindow() throws {
        try write("fresh.jpg", age: 10)
        try write("stale.jpg", age: 600)
        store.clearDownloaded(keeping: [])
        XCTAssertEqual(remaining, ["fresh.jpg"])
    }
}
