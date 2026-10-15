import CloudKit
import XCTest

/// Stuck, not slow (`UploadWatch`, `withStallWatch`), an upload's outcome
/// (`UploadHandle`, `CloudSync.attach`), and the retry order (`UploadOrder`).
final class UploadPolicyTests: XCTestCase {
    private let t0 = Fixtures.t0

    /// Ticks every 5 s from `start` until a stall or `limit`; the stall's time, if any.
    private func stallTime(_ watch: inout UploadWatch, from start: Date, limit: TimeInterval = 600) -> Date? {
        var now = start
        while now < start.addingTimeInterval(limit) {
            now += 5
            if watch.tick(at: now, interval: 5, timeout: 90) == .stalled { return now }
        }
        return nil
    }

    func testASlowUploadThatKeepsMovingIsNeverStalled() {
        var watch = UploadWatch(startedAt: t0)
        for step in 1...200 {
            let now = t0.addingTimeInterval(Double(step) * 5)
            watch.progressed(to: Double(step) / 1_000, at: now)
            XCTAssertEqual(watch.tick(at: now, interval: 5, timeout: 90), .moving, "1,000 s and still crawling is fine")
        }
    }

    func testNoMovementForTheTimeoutIsAStall() {
        var watch = UploadWatch(startedAt: t0)
        watch.progressed(to: 0.3, at: t0 + 10)
        _ = watch.tick(at: t0 + 10, interval: 5, timeout: 90)
        XCTAssertEqual(stallTime(&watch, from: t0 + 10), t0 + 100)
    }

    /// Preparing the asset and committing the record report no progress.
    func testTheQuietPhasesGetTwiceAsLong() {
        var before = UploadWatch(startedAt: t0)
        XCTAssertEqual(stallTime(&before, from: t0), t0 + 180, "not even the first byte")
        var after = UploadWatch(startedAt: t0)
        after.progressed(to: 1, at: t0 + 10)
        _ = after.tick(at: t0 + 10, interval: 5, timeout: 90)
        XCTAssertEqual(stallTime(&after, from: t0 + 10), t0 + 190, "every byte sent, waiting on the commit")
    }

    /// CloudKit restarting a dropped transfer starts the fraction over: still moving.
    func testAProgressDropIsMovement() {
        var watch = UploadWatch(startedAt: t0)
        watch.progressed(to: 0.8, at: t0 + 10)
        _ = watch.tick(at: t0 + 10, interval: 5, timeout: 90)
        watch.progressed(to: 0.1, at: t0 + 80)
        XCTAssertEqual(stallTime(&watch, from: t0 + 10), t0 + 170)
    }

    func testRepeatedProgressIsNotMovement() {
        var watch = UploadWatch(startedAt: t0)
        watch.progressed(to: 0.5, at: t0 + 10)
        _ = watch.tick(at: t0 + 10, interval: 5, timeout: 90)
        watch.progressed(to: 0.5, at: t0 + 60)
        watch.progressed(to: .nan, at: t0 + 70)
        XCTAssertEqual(stallTime(&watch, from: t0 + 10), t0 + 100)
    }

    /// Suspended, the app can't see iCloud carrying on: the gap isn't a stall.
    func testASuspensionGapRestartsTheClock() {
        var watch = UploadWatch(startedAt: t0)
        XCTAssertEqual(watch.tick(at: t0 + 5, interval: 5, timeout: 90), .moving)
        XCTAssertEqual(watch.tick(at: t0 + 600, interval: 5, timeout: 90), .moving)
        XCTAssertEqual(stallTime(&watch, from: t0 + 600), t0 + 780)
    }

    // MARK: withStallWatch and UploadHandle

    func testAStalledUploadIsCancelledAndTheCallerResumes() async {
        let cancelled = expectation(description: "the upload saw its cancellation")
        do {
            try await withStallWatch(interval: 0.05, timeout: 0.1) { _ in
                await withTaskCancellationHandler {
                    try? await Task.sleep(for: .seconds(5))
                } onCancel: {
                    cancelled.fulfill()
                }
            }
            XCTFail("expected a stall")
        } catch {
            XCTAssertTrue(error is UploadStalled)
        }
        await fulfillment(of: [cancelled], timeout: 5)
    }

    func testAMovingUploadOutlastsTheTimeout() async throws {
        try await withStallWatch(interval: 0.02, timeout: 0.1) { progress in
            for step in 1...30 {
                progress(Double(step) / 31)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func testAnUploadHandleKeepsItsFirstOutcomeForLateWaiters() async throws {
        let handle = UploadHandle(cancel: {})
        handle.settle(.success(()))
        handle.settle(.failure(CKError(.networkFailure)))
        try await handle.value()
        try await handle.value()
    }

    func testCancellingTheWaiterCancelsTheUpload() async {
        let cancelled = expectation(description: "operation cancelled")
        let handle = UploadHandle(cancel: { cancelled.fulfill() })
        let waiter = Task { try await handle.value() }
        waiter.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        handle.settle(.failure(CKError(.operationCancelled)))
        _ = await waiter.result
    }

    // MARK: CloudKit's results, mapped (invariant 22)

    private func operation() -> (CKModifyRecordsOperation, CKRecord.ID) {
        let id = CKRecord.ID(recordName: "moment-owner-a", zoneID: Fixtures.zone)
        let record = CKRecord(recordType: CloudSync.RecordType.moment, recordID: id)
        return (CloudSync.uploadOperation(record), id)
    }

    func testAnUploadIsConfirmedOnlyByItsOwnRecord() async {
        let (operation, id) = operation()
        let handle = CloudSync.attach(operation, recordID: id)
        operation.modifyRecordsResultBlock?(.success(()))
        do {
            try await handle.value()
            XCTFail("success without the record's own result isn't a save")
        } catch {
            guard case SyncError.saveUnconfirmed = error else { return XCTFail("got \(error)") }
        }
    }

    func testTheRecordsOwnErrorWinsOverTheOperations() async {
        let (operation, id) = operation()
        let handle = CloudSync.attach(operation, recordID: id)
        operation.perRecordSaveBlock?(id, .failure(CKError(.quotaExceeded)))
        operation.modifyRecordsResultBlock?(.failure(CKError(.partialFailure)))
        do {
            try await handle.value()
            XCTFail("expected the record's failure")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .quotaExceeded)
        }
    }

    /// A late cancel failing the operation after the record committed: still sent.
    func testASavedRecordWinsOverALateOperationFailure() async throws {
        let (operation, id) = operation()
        let handle = CloudSync.attach(operation, recordID: id)
        operation.perRecordSaveBlock?(id, .success(CKRecord(recordType: CloudSync.RecordType.moment, recordID: id)))
        operation.modifyRecordsResultBlock?(.failure(CKError(.operationCancelled)))
        try await handle.value()
    }

    func testASavedRecordConfirms() async throws {
        let (operation, id) = operation()
        let handle = CloudSync.attach(operation, recordID: id)
        operation.perRecordSaveBlock?(id, .success(CKRecord(recordType: CloudSync.RecordType.moment, recordID: id)))
        operation.modifyRecordsResultBlock?(.success(()))
        try await handle.value()
        XCTAssertEqual(operation.configuration.qualityOfService, .userInitiated, "never discretionary")
        XCTAssertTrue(operation.configuration.isLongLived)
    }

    // MARK: Order

    func testRetriesGoSmallestFirstKeepingTiesInOrder() {
        let moments = ["photo", "memo", "doodle", "memo2"].map { Fixtures.moment($0, fromMe: true) }
        let sizes = ["photo": 900_000, "memo": 60_000, "doodle": 300_000, "memo2": 60_000]
        XCTAssertEqual(UploadOrder.smallestFirst(moments) { sizes[$0.id] ?? 0 }.map(\.id),
                       ["memo", "memo2", "doodle", "photo"])
    }
}
