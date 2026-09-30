import XCTest

/// The production channel under invariants 1, 3 and 15: the file-backed key/value
/// store (and its one-time `UserDefaults` migration) and the `flock` lock, run
/// against a temporary directory — never the real group container.
final class GroupStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        temporaryFile("unused").deletingLastPathComponent()
    }

    // MARK: CrossProcessLock

    /// Two lock objects on one file stand in for two processes: `flock` contends
    /// per open file description, so an unlocked read-modify-write would lose updates.
    func testLockSerialisesReadModifyWrites() throws {
        let directory = temporaryDirectory()
        let counter = directory.appendingPathComponent("counter")
        try Data("0".utf8).write(to: counter)
        let locks = [CrossProcessLock(name: "counter.lock", directory: directory),
                     CrossProcessLock(name: "counter.lock", directory: directory)]
        XCTAssertTrue(locks.allSatisfy(\.isFileBacked))

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            locks[i % 2].withLock {
                let value = Int(String(decoding: (try? Data(contentsOf: counter)) ?? Data(), as: UTF8.self)) ?? 0
                try? Data(String(value + 1).utf8).write(to: counter)
            }
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: counter), as: UTF8.self), "200")
    }

    func testNoDirectoryRunsTheBodyBare() {
        let lock = CrossProcessLock(name: "x.lock", directory: nil)
        XCTAssertFalse(lock.isFileBacked)
        XCTAssertEqual(lock.withLock { 42 }, 42)
    }

    // MARK: GroupFileStore

    private func makeStore(legacy: UserDefaults? = nil, isAppExtension: Bool = false,
                           in directory: URL? = nil) -> (GroupFileStore, URL) {
        let directory = directory ?? temporaryDirectory().appendingPathComponent("State", isDirectory: true)
        return (GroupFileStore(directory: directory, legacy: legacy, isAppExtension: isAppExtension), directory)
    }

    func testValuesRoundTripAndNilRemovesTheFile() {
        let (store, directory) = makeStore()
        store.setData(Data([1, 2, 3]), forKey: "snapshot")
        XCTAssertEqual(store.data(forKey: "snapshot"), Data([1, 2, 3]))
        store.setBool(true, forKey: "inviteClosed")
        XCTAssertTrue(store.bool(forKey: "inviteClosed"))
        XCTAssertFalse(store.bool(forKey: "never-set"))

        store.setData(nil, forKey: "snapshot")
        XCTAssertNil(store.data(forKey: "snapshot"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot").path))
    }

    /// Only the snapshot, pairing and change tokens move; an existing file wins.
    func testMigrationCopiesOnlyTheListedKeysOnce() throws {
        let legacy = temporaryDefaults()
        legacy.set(Data("old-snapshot".utf8), forKey: "snapshot")
        legacy.set(Data("old-pairing".utf8), forKey: "pairing")
        legacy.set(Data("token".utf8), forKey: "changeToken-private")
        legacy.set(Data("ignored".utf8), forKey: "somethingElse")

        let directory = temporaryDirectory().appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("newer-pairing".utf8).write(to: directory.appendingPathComponent("pairing"))

        let (store, _) = makeStore(legacy: legacy, in: directory)
        XCTAssertEqual(store.data(forKey: "snapshot"), Data("old-snapshot".utf8))
        XCTAssertEqual(store.data(forKey: "pairing"), Data("newer-pairing".utf8), "never overwrites a migrated file")
        XCTAssertEqual(store.data(forKey: "changeToken-private"), Data("token".utf8))
        XCTAssertNil(store.data(forKey: "somethingElse"))

        // Marked done: a second store doesn't re-copy a value deleted since.
        store.setData(nil, forKey: "snapshot")
        let (again, _) = makeStore(legacy: legacy, in: directory)
        XCTAssertNil(again.data(forKey: "snapshot"))
    }

    /// An extension's view of the suite can be empty; only the app may declare
    /// a no-op migration done, or a pairing still in the suite would be lost.
    func testOnlyTheAppMarksAnEmptyMigrationDone() {
        let directory = temporaryDirectory().appendingPathComponent("State", isDirectory: true)
        _ = makeStore(legacy: temporaryDefaults(), isAppExtension: true, in: directory)

        let legacy = temporaryDefaults()
        legacy.set(Data("pairing".utf8), forKey: "pairing")
        let (afterExtension, _) = makeStore(legacy: legacy, isAppExtension: false, in: directory)
        XCTAssertEqual(afterExtension.data(forKey: "pairing"), Data("pairing".utf8),
                       "the extension's empty pass didn't block the real migration")

        let appDirectory = temporaryDirectory().appendingPathComponent("State", isDirectory: true)
        _ = makeStore(legacy: temporaryDefaults(), isAppExtension: false, in: appDirectory)
        let (afterApp, _) = makeStore(legacy: legacy, isAppExtension: false, in: appDirectory)
        XCTAssertNil(afterApp.data(forKey: "pairing"), "the app's empty pass marks it done")
    }

    /// Invariant 15 through the real store: an unreadable snapshot is set aside, not overwritten.
    func testCorruptSnapshotIsPreservedThroughTheFileStore() {
        let (files, directory) = makeStore()
        files.setData(Data("not json".utf8), forKey: "snapshot")
        let store = SharedStore(store: files)
        XCTAssertEqual(store.snapshot, .empty)
        let sidecars = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(sidecars.contains { $0.hasPrefix("snapshot") && $0.contains("corrupt") }, "\(sidecars)")
    }
}
