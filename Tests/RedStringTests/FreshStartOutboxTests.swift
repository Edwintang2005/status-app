import CloudKit
import XCTest

/// The fresh start's loop in `Outbox` against `FakeBackend` and throwaway
/// stores: asks that aren't queued, answers that are, the automatic commit,
/// and a clear that touches this device's copy only once the zone half is done.
@MainActor
final class FreshStartOutboxTests: XCTestCase {
    private var store: SharedStore!
    private var index: MomentIndex!
    private var statusLog: StatusHistoryLog!
    private var backend: FakeBackend!
    private var outbox: Outbox!
    private var deletedMedia: [String] = []
    private let epoch = Fixtures.date(1_000)

    override func setUp() async throws {
        store = SharedStore(defaults: temporaryDefaults())
        store.pairing = PairingInfo(role: .owner, zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: CKCurrentUserDefaultName, pairedAt: Fixtures.t0)
        index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        statusLog = StatusHistoryLog(fileURL: temporaryFile("status-history.json"))
        backend = FakeBackend()
        backend.freshStartSavedAt = epoch
        deletedMedia = []
        let backend = backend!
        outbox = Outbox(store: store,
                        index: index,
                        statusLog: statusLog,
                        backend: { backend },
                        hasMedia: { _ in true },
                        deleteMedia: { [unowned self] in self.deletedMedia.append($0) },
                        protect: { _, body in try await body() },
                        indexChanged: {})
    }

    private var freshStart: FreshStart { store.snapshot.freshStart }

    func testAnAskIsSentAtOnceOrNotAtAll() async throws {
        backend.fail("freshStart", with: CKError(.networkFailure))
        do {
            _ = try await outbox.askForFreshStart()
            XCTFail("an offline ask must say so")
        } catch {}
        XCTAssertNil(freshStart.pendingIntent, "never queued: its epoch is when it reaches iCloud")
        XCTAssertNil(freshStart.mine)

        let asked = try await outbox.askForFreshStart()
        XCTAssertTrue(asked)
        XCTAssertEqual(freshStart.mine, FreshStartRecord(stage: .asking, epoch: epoch), "the server's time")
        XCTAssertNil(freshStart.pendingIntent)
    }

    func testAnAnswerIsQueuedOfflineAndSentOnTheNextPass() async {
        store.mutate { $0.freshStart.theirs = FreshStartRecord(stage: .asking, epoch: self.epoch) }
        backend.fail("freshStart", with: CKError(.networkFailure))
        let result = await outbox.publishFreshStart(.agree(epoch))
        XCTAssertNil(result)
        XCTAssertEqual(freshStart.pendingIntent, .agree(epoch))
        XCTAssertEqual(freshStart.mine?.stage, .agreeing, "shown as agreed here at once")

        await outbox.advanceFreshStart()
        XCTAssertNil(freshStart.pendingIntent)
        XCTAssertEqual(backend.freshStartServer, FreshStartRecord(stage: .agreeing, epoch: epoch))
        XCTAssertTrue(backend.clears.isEmpty, "no clear before the asker commits")
    }

    /// The asker's phone commits on seeing the yes, clears the zone half, then
    /// its own copy — the zone deciding by server time — and says it's done.
    func testTheAskerCommitsClearsAndCompletes() async {
        backend.freshStartServer = FreshStartRecord(stage: .asking, epoch: epoch)
        store.mutate {
            $0.freshStart.mine = FreshStartRecord(stage: .asking, epoch: self.epoch)
            $0.freshStart.theirs = FreshStartRecord(stage: .agreeing, epoch: self.epoch)
            $0.mine = Fixtures.status("🌱", "now", at: Fixtures.date(500))
        }
        index.insert([Fixtures.moment("old", at: Fixtures.date(100)),
                      Fixtures.moment("new", at: Fixtures.date(1_500)),
                      Fixtures.moment("unsent", at: Fixtures.date(100), fromMe: true, uploaded: false)])
        statusLog.record([StatusHistoryEntry(emoji: "🥰", message: "", isCelebration: false,
                                             at: Fixtures.date(100), fromMe: false),
                          StatusHistoryEntry(emoji: "🌱", message: "now", isCelebration: false,
                                             at: Fixtures.date(500), fromMe: true)])
        backend.clearZone = FreshStartPolicy.Zone(momentsBefore: ["old"], momentsAfter: ["new"])

        let changed = await outbox.advanceFreshStart()
        XCTAssertTrue(changed)
        XCTAssertEqual(backend.freshStartIntents, [.commit(epoch), .complete(epoch)])
        XCTAssertEqual(backend.clears.map(\.epoch), [epoch])
        XCTAssertEqual(backend.clears.first?.keep, Fixtures.date(500), "the status still showing keeps its log record")
        XCTAssertEqual(Set(index.load().map(\.id)), ["new", "unsent"], "an unsent send is the only copy")
        XCTAssertEqual(deletedMedia, ["old"])
        XCTAssertEqual(statusLog.load().map(\.message), ["now"])
        XCTAssertEqual(freshStart.finishedBefore, epoch)
        XCTAssertEqual(freshStart.clearedBefore, epoch)
        XCTAssertEqual(backend.freshStartServer, FreshStartRecord(stage: .idle, clearedBefore: epoch))
        XCTAssertTrue(store.snapshot.receiptsDirty, "the receipt went with the clear and is published afresh")

        let again = await outbox.advanceFreshStart()
        XCTAssertFalse(again, "done")
    }

    /// The zone half failing leaves this device's copy untouched; the next pass runs it all again.
    func testAFailedClearTouchesNothingHereAndRetries() async {
        store.mutate {
            $0.freshStart.mine = FreshStartRecord(stage: .agreeing, epoch: self.epoch)
            $0.freshStart.theirs = FreshStartRecord(stage: .committed, epoch: self.epoch)
        }
        index.insert([Fixtures.moment("old", at: Fixtures.date(100))])
        backend.clearZone = FreshStartPolicy.Zone(momentsBefore: ["old"])
        backend.fail("clear", with: CKError(.networkFailure))

        await outbox.advanceFreshStart()
        XCTAssertEqual(index.load().map(\.id), ["old"])
        XCTAssertNil(freshStart.finishedBefore)
        XCTAssertNotNil(outbox.freshStartFailure)

        await outbox.advanceFreshStart()
        XCTAssertTrue(index.load().isEmpty)
        XCTAssertEqual(freshStart.finishedBefore, epoch)
        XCTAssertNil(outbox.freshStartFailure)
    }

    /// A pending send the clear is deleting must not be re-sent around it.
    func testNoUploadRetryRunsWhileClearing() async {
        store.mutate {
            $0.freshStart.mine = FreshStartRecord(stage: .agreeing, epoch: self.epoch)
            $0.freshStart.theirs = FreshStartRecord(stage: .committed, epoch: self.epoch)
        }
        index.insert([Fixtures.moment("landedEarly", at: Fixtures.date(100), fromMe: true, uploaded: false)])
        backend.clearZone = FreshStartPolicy.Zone(momentsBefore: ["landedEarly"])
        let outbox = outbox!
        let retried = Box()
        backend.duringClear = {
            Task { @MainActor in retried.value = await outbox.retryPendingUploads(automatic: false) }
        }
        await outbox.advanceFreshStart()
        for _ in 0..<100 where retried.value == nil { await Task.yield() }
        XCTAssertEqual(retried.value, false)
        XCTAssertTrue(backend.sent.isEmpty)
        XCTAssertTrue(index.load().isEmpty, "it reached iCloud before the epoch: cleared, not re-sent")
    }

    func testAWithdrawAfterTheCommitIsRefused() async {
        backend.freshStartServer = FreshStartRecord(stage: .committed, epoch: epoch)
        store.mutate { $0.freshStart.mine = FreshStartRecord(stage: .asking, epoch: self.epoch) }
        let result = await outbox.publishFreshStart(.withdraw)
        XCTAssertEqual(result, .refused(FreshStartRecord(stage: .committed, epoch: epoch)))
        XCTAssertEqual(freshStart.mine?.stage, .committed, "the server's copy is adopted")
        XCTAssertNil(freshStart.pendingIntent)
    }

    func testNothingIsWrittenWhileUnpaired() async throws {
        store.pairing = nil
        let asked = try await outbox.askForFreshStart()
        XCTAssertFalse(asked)
        await outbox.advanceFreshStart()
        XCTAssertTrue(backend.freshStartIntents.isEmpty)
    }
}

/// What a retry started from inside the fake backend answered.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
