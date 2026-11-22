import XCTest

/// "Save memories" around its writer: progress, the device-only share, a
/// cancel, and a failure — over an injected writer, so nothing is written.
@MainActor
final class ArchiveModelTests: XCTestCase {
    private func outcome(_ destination: ArchiveOutcome.Destination) -> ArchiveOutcome {
        ArchiveOutcome(folder: URL(fileURLWithPath: "/tmp/Memories"), destination: destination,
                       momentCount: 1, statusCount: 1, unrecovered: 0, unsupported: 0, gone: 0,
                       gate: .proceed, includesZone: true, unreadable: 0)
    }

    /// A model whose screen-awake requests are recorded.
    private func modelRecordingAwake() -> (AppModel, CloudStores, Box<[Bool]>) {
        let awake = Box<[Bool]>([])
        let stores = makeStores()
        var environment = AppEnvironment.detached
        environment.keepScreenAwake = { awake.value.append($0) }
        return (AppModel(stores: stores, backend: FakeAppBackend(), environment: environment), stores, awake)
    }

    private func archive(for model: AppModel, stores: CloudStores, writer: @escaping MemoryArchive.Writer) -> ArchiveModel {
        let archive = ArchiveModel(store: stores.shared, statusLog: stores.statusLog,
                                   backend: { FakeAppBackend() }, write: writer)
        archive.host = model
        return archive
    }

    func testASavedArchiveEndsItsProgress() async {
        let (model, _, stores) = makeModel()
        let archive = archive(for: model, stores: stores) { _, _, _, _, progress in
            progress(0.5)
            return self.outcome(.iCloudDrive)
        }
        let saved = await archive.archive()
        XCTAssertEqual(saved?.destination, .iCloudDrive)
        XCTAssertNil(archive.progress)
        XCTAssertNil(archive.toShare, "iCloud Drive: nothing to share")
        XCTAssertTrue(archive.canArchive)
    }

    func testADeviceOnlyArchiveIsOfferedForSharingUnlessTheCallerOffersIt() async {
        let (model, _, stores) = makeModel()
        let device = outcome(.deviceOnly)
        let archive = archive(for: model, stores: stores) { _, _, _, _, _ in device }
        await archive.archive(offeringShare: false)
        XCTAssertNil(archive.toShare, "the fresh start offers its own")
        await archive.archive()
        XCTAssertEqual(archive.toShare, device.folder)
    }

    func testACancelledArchiveReportsNothingWhenItWindsDown() async {
        let (model, stores, awake) = modelRecordingAwake()
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        let device = outcome(.deviceOnly)
        let archive = archive(for: model, stores: stores) { _, _, _, _, progress in
            // Deaf to cancellation, like a write already under way.
            await withCheckedContinuation { gate.value = $0 }
            progress(0.9)
            return device
        }
        let run = Task { await archive.archive() }
        await waitUntil { gate.value != nil }
        XCTAssertFalse(archive.canArchive, "one at a time")
        XCTAssertEqual(awake.value.last, true, "the screen stays on while it fetches")
        archive.cancel()
        XCTAssertNil(archive.progress)
        XCTAssertEqual(awake.value.last, false)
        gate.value?.resume()
        let result = await run.value
        // Its late progress hop has run by the time a later main-actor task does.
        await Task { @MainActor in }.value
        XCTAssertNil(result, "a cancelled run hands nothing on to a delete")
        XCTAssertNil(archive.toShare, "nor offers a share")
        XCTAssertNil(archive.progress, "nor brings its progress back")
    }

    func testTheScreenStaysOnOnlyWhileAnArchiveRuns() async {
        let (model, stores, awake) = modelRecordingAwake()
        let archive = archive(for: model, stores: stores) { _, _, _, _, _ in
            XCTAssertEqual(awake.value.last, true)
            return self.outcome(.iCloudDrive)
        }
        await archive.archive()
        XCTAssertEqual(awake.value, [true, false])
    }

    func testAFailureIsShown() async {
        let (model, _, stores) = makeModel()
        let archive = archive(for: model, stores: stores) { _, _, _, _, _ in throw MemoryArchive.ArchiveError.nothingToSave }
        let result = await archive.archive()
        XCTAssertNil(result)
        XCTAssertEqual(model.errorTitle, "Couldn't save your memories")
        XCTAssertNil(archive.progress)
    }

    func testNothingToSaveUnpairedWithAnEmptyHistory() {
        let (model, _, _) = makeModel(paired: nil)
        XCTAssertFalse(model.archive.hasMemories)
        XCTAssertFalse(model.archive.canArchive)
    }
}
