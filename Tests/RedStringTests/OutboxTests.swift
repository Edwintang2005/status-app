import CloudKit
import XCTest

/// A `SyncBackend` that records what was asked of it and fails on demand.
final class FakeBackend: SyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _published: [(payload: StatusPayload, logged: Bool)] = []
    private var _sent: [String] = []
    private var _receipts: [[String: Date]] = []
    private var _statusSeen: [StatusSeen?] = []
    private var _anniversaries: [Anniversary?] = []
    private var _requests: [Date] = []
    private var failures: [String: [Error]] = [:]
    /// Runs inside the call, before it returns — a write landing mid-flight.
    var duringPublish: (@Sendable () -> Void)?
    var duringReceipts: (@Sendable () -> Void)?

    var published: [(payload: StatusPayload, logged: Bool)] { lock.withLock { _published } }
    var sent: [String] { lock.withLock { _sent } }
    var receipts: [[String: Date]] { lock.withLock { _receipts } }
    var statusSeen: [StatusSeen?] { lock.withLock { _statusSeen } }
    var anniversaries: [Anniversary?] { lock.withLock { _anniversaries } }
    var requests: [Date] { lock.withLock { _requests } }

    /// The next `count` calls to `method` throw `error`.
    func fail(_ method: String, with error: Error, times count: Int = 1) {
        lock.withLock { failures[method, default: []] += Array(repeating: error, count: count) }
    }

    private func check(_ method: String) throws {
        let error: Error? = lock.withLock {
            guard var queue = failures[method], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            failures[method] = queue
            return first
        }
        if let error { throw error }
    }

    func readiness() async -> BackendReadiness { .ready }
    func publish(_ payload: StatusPayload, logged: Bool) async throws {
        duringPublish?()
        try check("publish")
        lock.withLock { _published.append((payload, logged)) }
    }
    @discardableResult func refresh() async throws -> RefreshResult { .empty }
    @discardableResult func sendNudge() async throws -> Bool { true }
    func send(_ moment: Moment) async throws {
        try check("send")
        lock.withLock { _sent.append(moment.id) }
    }
    func fetchMedia(for moment: Moment) async throws {}
    func fetchThumbnail(for moment: Moment) async throws {}
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws {
        duringReceipts?()
        try check("receipts")
        lock.withLock {
            _receipts.append(seen)
            _statusSeen.append(statusSeen)
        }
    }
    func publishAnniversary(_ anniversary: Anniversary?) async throws {
        try check("anniversary")
        lock.withLock { _anniversaries.append(anniversary) }
    }
    func publishAnniversaryRequest(at date: Date) async throws {
        try check("request")
        lock.withLock { _requests.append(date) }
    }
    func registerSubscription() async throws {}
    func noteAccountChanged() async {}
    func unpair() async throws {}
}

/// The offline-send loops against a fake backend and throwaway stores
/// (invariants 11, 13, 16, and the full-iCloud back-off).
@MainActor
final class OutboxTests: XCTestCase {
    private var store: SharedStore!
    private var index: MomentIndex!
    private var backend: FakeBackend!
    private var outbox: Outbox!
    /// Moment ids whose media is "on disk".
    private var media: Set<String> = []
    /// Times the outbox told the store its index lost an entry.
    private var indexChanges = 0

    override func setUp() async throws {
        store = SharedStore(defaults: temporaryDefaults())
        store.pairing = PairingInfo(role: .owner, zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: CKCurrentUserDefaultName, pairedAt: Fixtures.t0)
        index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        backend = FakeBackend()
        media = []
        indexChanges = 0
        let backend = backend!
        outbox = Outbox(store: store,
                        index: index,
                        backend: { backend },
                        hasMedia: { [unowned self] in self.media.contains($0.id) },
                        protect: { _, body in try await body() },
                        indexChanged: { [unowned self] in self.indexChanges += 1 })
    }

    private var quota: CKError { CKError(.quotaExceeded) }

    // MARK: Status (invariants 11, 16)

    func testUnpublishedStatusIsRepublishedAndMarked() async {
        let mine = Fixtures.status("🍜", "lunch")
        store.mutate { $0.mine = mine; $0.myStatusPublished = false }

        let changed = await outbox.republishStatus()
        XCTAssertTrue(changed)
        XCTAssertEqual(backend.published.map(\.payload), [mine])
        XCTAssertEqual(backend.published.first?.logged, true, "its log record isn't confirmed yet")
        XCTAssertTrue(store.snapshot.myStatusPublished)

        let again = await outbox.republishStatus()
        XCTAssertFalse(again, "nothing left to send")
        XCTAssertEqual(backend.published.count, 1)
    }

    /// A rename retried offline must not log its old words as a new status.
    func testRetriedRenameIsNotLogged() async {
        let mine = Fixtures.status("🍜", "lunch")
        store.mutate { $0.mine = mine; $0.myStatusPublished = false; $0.myStatusLoggedAt = mine.wordsAt }
        await outbox.republishStatus()
        XCTAssertEqual(backend.published.first?.logged, false)
    }

    func testANewerEditDuringThePublishStaysUnpublished() async {
        let store = store!
        store.mutate { $0.mine = Fixtures.status("🍜", "lunch", at: Fixtures.t0); $0.myStatusPublished = false }
        backend.duringPublish = {
            store.mutate { $0.mine = Fixtures.status("☕️", "coffee?", at: Fixtures.date(10)) }
        }
        await outbox.republishStatus()
        XCTAssertFalse(store.snapshot.myStatusPublished, "the flag belongs to the newer, unsent status")
    }

    func testAFailedPublishKeepsTheFlagDown() async {
        store.mutate { $0.mine = Fixtures.status(); $0.myStatusPublished = false }
        backend.fail("publish", with: CKError(.networkFailure))
        let changed = await outbox.republishStatus()
        XCTAssertFalse(changed)
        XCTAssertFalse(store.snapshot.myStatusPublished)
        XCTAssertNil(outbox.storageFullAt, "a network failure isn't a full iCloud")
    }

    // MARK: Anniversary (owner) and its request (participant)

    func testAnniversaryRepublishesOnlyFromTheOwner() async {
        store.mutate { $0.anniversaryPublished = false }
        await outbox.republishAnniversary()
        XCTAssertEqual(backend.anniversaries.count, 1)
        XCTAssertTrue(store.snapshot.anniversaryPublished)

        store.pairing = PairingInfo(role: .participant, zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: "_owner", pairedAt: Fixtures.t0)
        store.mutate { $0.anniversaryPublished = false; $0.anniversaryRequestedAt = Fixtures.t0; $0.anniversaryRequestPublished = false }
        await outbox.republishAnniversary()
        XCTAssertEqual(backend.anniversaries.count, 1, "the participant never writes the date")
        await outbox.republishAnniversaryRequest()
        XCTAssertEqual(backend.requests, [Fixtures.t0])
        XCTAssertTrue(store.snapshot.anniversaryRequestPublished)
    }

    func testTheOwnerNeverAsksForTheDate() async {
        store.mutate { $0.anniversaryRequestedAt = Fixtures.t0; $0.anniversaryRequestPublished = false }
        await outbox.republishAnniversaryRequest()
        XCTAssertTrue(backend.requests.isEmpty)
    }

    // MARK: Pending uploads (invariant 11) and a full iCloud

    private func queue(_ ids: [String], at base: TimeInterval = 0) {
        index.insert(ids.enumerated().map { offset, id in
            Fixtures.moment(id, at: Fixtures.date(base + Double(offset)), fromMe: true, uploaded: false)
        })
        media.formUnion(ids)
    }

    func testPendingUploadsAreSentAndMarked() async {
        queue(["a", "b"])
        let changed = await outbox.retryPendingUploads(automatic: true)
        XCTAssertTrue(changed)
        XCTAssertEqual(Set(backend.sent), ["a", "b"])
        XCTAssertTrue(index.load().allSatisfy(\.uploaded))
    }

    func testAPendingSendWithNoMediaIsDroppedNotRetriedForever() async {
        queue(["ghost"])
        media.remove("ghost")
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertTrue(backend.sent.isEmpty)
        XCTAssertTrue(index.load().isEmpty)
        XCTAssertEqual(indexChanges, 1, "the snapshot's derived fields are recomputed")
    }

    /// Only a full iCloud stops the pass; anything else is that one send's problem.
    func testATransientFailureMovesOnToTheNextSend() async {
        queue(["a", "b"])
        backend.fail("send", with: CKError(.networkFailure))
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent.count, 1)
        XCTAssertEqual(index.load().filter { !$0.uploaded }.count, 1, "the failed one stays queued")
        XCTAssertNil(outbox.storageFullAt)
    }

    func testAFullICloudStopsThePassAndHoldsOffAutomaticRetries() async {
        queue(["a", "b"])
        backend.fail("send", with: quota)
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertTrue(backend.sent.isEmpty, "the second would hit the same full iCloud")
        XCTAssertNotNil(outbox.storageFullAt)

        await outbox.retryPendingUploads(automatic: true)
        XCTAssertTrue(backend.sent.isEmpty, "automatic passes wait")

        let later = Date().addingTimeInterval(AppConfig.storageFullRetryInterval + 1)
        await outbox.retryPendingUploads(automatic: true, now: later)
        XCTAssertEqual(Set(backend.sent), ["a", "b"], "and resume after the interval")
        XCTAssertNil(outbox.storageFullAt, "a landed send proves there's room")
    }

    func testTheFootersTapRetriesAtOnce() async {
        queue(["a"])
        backend.fail("send", with: quota)
        await outbox.retryPendingUploads(automatic: true)
        await outbox.retryPendingUploads(automatic: false)
        XCTAssertEqual(backend.sent, ["a"])
    }

    func testQuotaInsideAPartialFailureCounts() async {
        store.mutate { $0.mine = Fixtures.status(); $0.myStatusPublished = false }
        let item = CKRecord.ID(recordName: "status-owner")
        backend.fail("publish", with: CKError(.partialFailure,
                                              userInfo: [CKPartialErrorsByItemIDKey: [item: CKError(.quotaExceeded)]]))
        await outbox.republishStatus()
        XCTAssertNotNil(outbox.storageFullAt)
    }

    // MARK: Receipts (invariant 13)

    func testReceiptsAreClaimedBeforeTheCallAndReDirtiedOnFailure() async {
        index.insert([Fixtures.moment("seen", seen: true)])
        store.mutate { $0.receiptsDirty = true }
        backend.fail("receipts", with: CKError(.networkFailure))
        await outbox.flushReceipts()
        XCTAssertTrue(store.snapshot.receiptsDirty, "left for the next refresh")

        await outbox.flushReceipts()
        XCTAssertEqual(backend.receipts.map { Set($0.keys) }, [["seen"]])
        XCTAssertFalse(store.snapshot.receiptsDirty)
    }

    func testAMarkSeenLandingMidFlightIsPublishedToo() async {
        let store = store!
        let backend = backend!
        store.mutate { $0.receiptsDirty = true }
        backend.duringReceipts = {
            // Only during the first publish.
            guard backend.receipts.isEmpty else { return }
            store.mutate { $0.receiptsDirty = true }
        }
        await outbox.flushReceipts()
        XCTAssertEqual(backend.receipts.count, 2)
        XCTAssertFalse(store.snapshot.receiptsDirty)
    }

    /// Invariant 13: turned off, receipts retract — an empty map and no status receipt.
    func testDisabledReceiptsRetractWithAnEmptyMap() async {
        let seen = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: Fixtures.date(5))
        index.insert([Fixtures.moment("seen", seen: true)])
        store.mutate { $0.receiptsDirty = true; $0.partnerStatusSeen = seen }
        await outbox.flushReceipts()
        XCTAssertEqual(backend.statusSeen, [seen], "on: the status receipt travels")

        store.readReceiptsEnabled = false
        store.mutate { $0.receiptsDirty = true }
        await outbox.flushReceipts()
        XCTAssertEqual(backend.receipts.last, [:])
        XCTAssertEqual(backend.statusSeen.last, .some(nil))
    }

    func testNothingIsSentWhileUnpaired() async {
        store.pairing = nil
        store.mutate { $0.mine = Fixtures.status(); $0.myStatusPublished = false; $0.receiptsDirty = true }
        queue(["a"])
        await outbox.republishStatus()
        await outbox.retryPendingUploads(automatic: false)
        await outbox.flushReceipts()
        XCTAssertTrue(backend.published.isEmpty && backend.sent.isEmpty && backend.receipts.isEmpty)
    }
}
