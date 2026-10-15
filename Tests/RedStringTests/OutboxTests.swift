import CloudKit
import XCTest

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
    /// Moments the outbox reported delivered, first time or on a retry.
    private var confirmed: [String] = []
    private var statusLog: StatusHistoryLog!
    /// Moment ids whose files the outbox deleted.
    private var deletedMedia: [String] = []

    override func setUp() async throws {
        store = SharedStore(defaults: temporaryDefaults())
        store.pairing = PairingInfo(role: .owner, zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: CKCurrentUserDefaultName, pairedAt: Fixtures.t0)
        index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        backend = FakeBackend()
        media = []
        indexChanges = 0
        confirmed = []
        deletedMedia = []
        statusLog = StatusHistoryLog(fileURL: temporaryFile("status-history.json"), onCorrupt: {})
        outbox = .testing(store: store, index: index, statusLog: statusLog, backend: backend,
                          hasMedia: { [unowned self] in self.media.contains($0.id) },
                          deleteMedia: { [unowned self] in self.deletedMedia.append($0) },
                          indexChanged: { [unowned self] in self.indexChanges += 1 },
                          uploaded: { [unowned self] in self.confirmed.append($0.id) })
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

    func testADateSetDuringTheSendGoesOutAfterIt() async {
        let first = Anniversary(startsAt: Fixtures.date(1_000), timeZoneID: "UTC")
        let second = Anniversary(startsAt: Fixtures.date(2_000), timeZoneID: "UTC")
        store.mutate { $0.anniversary = first; $0.anniversaryPublished = false }
        let (store, backend) = (store!, backend!)
        backend.duringAnniversary = { [unowned backend] in
            backend.duringAnniversary = nil
            // The editor's write, refused by the in-flight guard.
            store.mutate { $0.anniversary = second; $0.anniversaryPublished = false }
        }
        await outbox.republishAnniversary()
        XCTAssertEqual(backend.anniversaries, [first, second])
        XCTAssertTrue(store.snapshot.anniversaryPublished)
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
        backend.fail("send", with: CKError(.internalError))
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent.count, 1)
        XCTAssertEqual(index.load().filter { !$0.uploaded }.count, 1, "the failed one stays queued")
        XCTAssertNil(outbox.storageFullAt)
    }

    func testNoConnectionStopsThePassButNotLaterOnes() async {
        queue(["a", "b"])
        backend.fail("send", with: CKError(.networkUnavailable))
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertTrue(backend.sent.isEmpty, "the second would hit the same dead connection")
        XCTAssertNil(outbox.storageFullAt, "offline isn't a full iCloud")
        XCTAssertEqual(index.load().filter { !$0.uploaded }.count, 2)

        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(Set(backend.sent), ["a", "b"], "the reconnect pass sends both, no back-off")
    }

    func testUnpublishedCountMirrorsTheRepublishGuards() {
        var snapshot = Snapshot.empty
        XCTAssertEqual(snapshot.unpublishedCount(role: .owner), 0)
        snapshot.mine = Fixtures.status()
        snapshot.myStatusPublished = false
        snapshot.anniversaryPublished = false
        snapshot.anniversaryRequestPublished = false
        XCTAssertEqual(snapshot.unpublishedCount(role: .owner), 2, "the owner never sends a request")
        XCTAssertEqual(snapshot.unpublishedCount(role: .participant), 1, "nor the participant a date; no ask on file")
        snapshot.anniversaryRequestedAt = Fixtures.t0
        XCTAssertEqual(snapshot.unpublishedCount(role: .participant), 2)
        snapshot.freshStart.pendingIntent = .withdraw
        XCTAssertEqual(snapshot.unpublishedCount(role: .participant), 3, "a queued fresh start answer waits too")
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

    // MARK: Review fixes (October 2026)

    /// A refresh's retry pass landing during a send's own upload leaves it
    /// alone — it was uploaded twice — and it isn't "waiting to send" meanwhile.
    func testARetryPassSkipsASendStillUploading() async throws {
        queue(["a"])
        let outbox = outbox!
        let moment = try XCTUnwrap(index.load().first)
        let seenInFlight = Flag()
        backend.duringSend = { id in
            guard id == "a" else { return }
            await MainActor.run { seenInFlight.value = outbox.uploadsInFlight.contains("a") }
            await outbox.retryPendingUploads(automatic: true)
        }
        try await outbox.upload(moment)
        XCTAssertEqual(backend.sent, ["a"], "one upload, not two")
        XCTAssertTrue(seenInFlight.value)
        XCTAssertTrue(outbox.uploadsInFlight.isEmpty)
        XCTAssertEqual(index.load().first?.uploaded, true)
    }

    /// A send that went out on a retry confirms like a first one.
    func testARetriedSendIsConfirmed() async {
        queue(["a"])
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(confirmed, ["a"])
    }

    func testAFailedUploadIsNotConfirmedAndStaysQueued() async throws {
        queue(["a"])
        let moment = try XCTUnwrap(index.load().first)
        backend.fail("send", with: CKError(.networkFailure))
        do {
            try await outbox.upload(moment)
            XCTFail("the failure reaches the caller, which words it")
        } catch {}
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertEqual(index.load().first?.uploaded, false)
        XCTAssertNil(outbox.throttledUntil)
    }

    /// CloudKit's retry-after holds automatic passes; the footer's tap doesn't wait.
    func testAThrottleHoldsAutomaticRetries() async {
        queue(["a", "b"])
        let now = Date()
        backend.fail("send", with: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 120)]))
        await outbox.retryPendingUploads(automatic: true, now: now)
        XCTAssertTrue(backend.sent.isEmpty, "the rest would be throttled too")
        XCTAssertEqual(outbox.throttledUntil, now.addingTimeInterval(120))

        await outbox.retryPendingUploads(automatic: true, now: now.addingTimeInterval(60))
        XCTAssertTrue(backend.sent.isEmpty, "inside the server's window")
        store.mutate { $0.mine = Fixtures.status(); $0.myStatusPublished = false }
        await outbox.republishStatus(automatic: true, now: now.addingTimeInterval(60))
        XCTAssertTrue(backend.published.isEmpty, "every automatic loop waits it out")

        await outbox.retryPendingUploads(automatic: true, now: now.addingTimeInterval(121))
        XCTAssertEqual(Set(backend.sent), ["a", "b"])
        XCTAssertNil(outbox.throttledUntil)
    }

    /// The status landed but its log didn't — only the log is owed, and
    /// the status shows as sent meanwhile.
    func testAPendingLogIsRetriedOnItsOwn() async {
        let mine = Fixtures.status("🍜", "lunch", at: Fixtures.date(10))
        store.mutate { $0.mine = mine; $0.myStatusPublished = true; $0.myStatusLoggedAt = Fixtures.t0 }
        XCTAssertEqual(store.snapshot.unpublishedCount(role: .owner), 0, "the status itself is sent")
        let changed = await outbox.republishStatus()
        XCTAssertTrue(changed)
        XCTAssertEqual(backend.published.first?.logged, true)

        let rename = Fixtures.status("🍜", "lunch", at: Fixtures.date(10))
        store.mutate { $0.mine = rename; $0.myStatusLoggedAt = rename.wordsAt }
        let again = await outbox.republishStatus()
        XCTAssertFalse(again, "nothing owed once the log matches the words")
    }

    /// A publish that keeps failing for another reason backs off.
    func testRepeatedStatusFailuresBackOff() async {
        store.mutate { $0.mine = Fixtures.status(); $0.myStatusPublished = false }
        let now = Date()
        backend.fail("publish", with: CKError(.internalError), times: 2)
        await outbox.republishStatus(automatic: true, now: now)
        await outbox.republishStatus(automatic: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(backend.published.count, 0)
        let delay = Outbox.statusRetryDelay(failures: 1)
        await outbox.republishStatus(automatic: true, now: now.addingTimeInterval(delay + 1))
        XCTAssertEqual(backend.published.count, 0, "the second attempt failed too")
        await outbox.republishStatus(automatic: false, now: now.addingTimeInterval(delay + 2))
        XCTAssertEqual(backend.published.count, 1, "the footer's tap doesn't wait")
        XCTAssertEqual(Outbox.statusRetryDelay(failures: 30), AppConfig.statusRetryMaxDelay)
    }

    /// Paging through new photos is one receipt write, not one per page.
    func testReceiptFlushesAreDebounced() async throws {
        index.insert([Fixtures.moment("seen", seen: true)])
        for _ in 0..<3 {
            store.mutate { $0.receiptsDirty = true }
            outbox.scheduleReceiptFlush(after: 0.05)
        }
        await waitUntil { !backend.receipts.isEmpty }
        XCTAssertEqual(backend.receipts.count, 1)

        store.mutate { $0.receiptsDirty = true }
        outbox.scheduleReceiptFlush(after: 60)
        await outbox.flushReceiptsNow()
        // The debounced flush may still be finishing; then its loop sends this — not in 60 s either way.
        await waitUntil { backend.receipts.count >= 2 }
        XCTAssertEqual(backend.receipts.count, 2, "backgrounding sends what the debounce held")
    }

    /// Own sends an older build's strict decode left in the sidecar go back in the queue.
    func testSalvagedSendsAreRetried() async throws {
        let url = temporaryFile("salvage/moments-index.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lost = Fixtures.moment("lost", fromMe: true, uploaded: false)
        try JSONEncoder.shared.encode([lost]).write(to: url.appendingPathExtension("corrupt"))
        let index = MomentIndex(fileURL: url, onCorrupt: {})
        let outbox = Outbox.testing(store: store, index: index, statusLog: statusLog, backend: backend)
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent, ["lost"])
        XCTAssertEqual(index.load().first?.uploaded, true)
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

    // MARK: Weak signal: uploads outliving their caller, order, background

    /// The caller stops waiting; the upload doesn't. It stays in flight — a
    /// retry pass mustn't send it a second time — and confirms when it lands.
    func testAnUploadOutlastingItsCallerStaysInFlightAndConfirms() async throws {
        queue(["a"])
        let moment = try XCTUnwrap(index.load().first)
        let gate = Gate()
        backend.duringSend = { _ in await gate.wait() }
        do {
            try await outbox.upload(moment, waitAtMost: 0.05)
            XCTFail("the caller gives up waiting")
        } catch {}
        XCTAssertTrue(outbox.uploadsInFlight.contains("a"))
        await outbox.retryPendingUploads(automatic: true)
        gate.open()
        await waitUntil { self.confirmed == ["a"] }
        XCTAssertEqual(backend.sent, ["a"], "sent once, not again by the retry")
        XCTAssertEqual(index.load().first?.uploaded, true)
        await waitUntil { self.outbox.uploadsInFlight.isEmpty }
    }

    func testRetriesGoSmallestFirst() async {
        queue(["photo", "memo", "doodle"])
        let sizes = ["photo": 900_000, "memo": 60_000, "doodle": 300_000]
        let outbox = Outbox.testing(store: store, index: index, statusLog: statusLog, backend: backend,
                                    uploadSize: { sizes[$0.id] ?? 0 })
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent, ["memo", "doodle", "photo"])
    }

    /// One upload at a time: a pass that finds another running stands aside.
    func testARetryPassStandsAsideWhileAnotherUploadRuns() async throws {
        queue(["a", "b"])
        let outbox = outbox!
        let moment = try XCTUnwrap(index.load().first { $0.id == "a" })
        backend.duringSend = { id in
            guard id == "a" else { return }
            await outbox.retryPendingUploads(automatic: true)
        }
        try await outbox.upload(moment)
        XCTAssertEqual(backend.sent, ["a"], "b waits for the link")
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent, ["a", "b"])
    }

    /// An upload iCloud carried on with across a relaunch is adopted, not
    /// re-sent, holds the link, and confirms when it lands.
    func testABackgroundUploadIsAdoptedNotSentAgain() async {
        queue(["a", "b"])
        let handle = UploadHandle(cancel: {})
        backend.backgroundUploads = [ResumedUpload(momentID: "a", handle: handle)]
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertTrue(backend.sent.isEmpty, "a is iCloud's; b waits for it")
        XCTAssertTrue(outbox.uploadsInFlight.contains("a"))
        handle.settle(.success(()))
        await waitUntil { self.confirmed == ["a"] }
        XCTAssertEqual(index.load().first { $0.id == "a" }?.uploaded, true)
        await waitUntil { self.outbox.uploadsInFlight.isEmpty }
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent, ["b"])
        XCTAssertEqual(backend.resumeCalls, 1, "adopted once per launch")
    }

    /// A pass stood aside for an upload that outlived its caller; when it
    /// lands with nothing else running, the queue is sent on at once.
    func testALateLandingSendsTheRestOfTheQueue() async throws {
        queue(["a", "b"])
        let outbox = outbox!
        outbox.linkFreed = { Task { await outbox.retryPendingUploads(automatic: true) } }
        let moment = try XCTUnwrap(index.load().first { $0.id == "a" })
        let gate = Gate()
        backend.duringSend = { id in if id == "a" { await gate.wait() } }
        try? await outbox.upload(moment, waitAtMost: 0.05)
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent, [], "b stands aside for a")
        gate.open()
        // On `confirmed`, not `sent`: the fake records a send before it's marked uploaded.
        await waitUntil { self.confirmed == ["a", "b"] }
        XCTAssertEqual(backend.sent, ["a", "b"])
        XCTAssertTrue(index.load().allSatisfy(\.uploaded))
    }

    /// The link is free only when the last upload lands, not the first of two.
    func testNoKickWhileAnotherUploadRuns() async throws {
        queue(["a", "b"])
        var freed = 0
        outbox.linkFreed = { freed += 1 }
        let gateA = Gate(), gateB = Gate()
        backend.duringSend = { id in await (id == "a" ? gateA : gateB).wait() }
        for id in ["a", "b"] {
            let moment = try XCTUnwrap(index.load().first { $0.id == id })
            try? await outbox.upload(moment, waitAtMost: 0.02)
        }
        gateA.open()
        await waitUntil { self.confirmed == ["a"] }
        XCTAssertEqual(freed, 0, "b still holds the link")
        gateB.open()
        await waitUntil { freed == 1 }
    }

    /// A background upload a refresh already filed doesn't say "Sent" again,
    /// but its landing still frees the link for the rest.
    func testAnAlreadyFiledBackgroundLandingStillFreesTheLink() async {
        queue(["a"])
        var freed = 0
        outbox.linkFreed = { freed += 1 }
        let handle = UploadHandle(cancel: {})
        backend.backgroundUploads = [ResumedUpload(momentID: "a", handle: handle)]
        await outbox.adoptBackgroundUploads()
        index.markUploaded(ids: ["a"])
        handle.settle(.success(()))
        await waitUntil { freed == 1 }
        XCTAssertTrue(confirmed.isEmpty)
    }

    /// No kick from a pass's own sends: the pass carries on by itself.
    func testARetryPassDoesntFreeTheLinkMidPass() async {
        queue(["a", "b"])
        var freed = 0
        outbox.linkFreed = { freed += 1 }
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(Set(backend.sent), ["a", "b"])
        XCTAssertEqual(freed, 0)
    }

    /// A look that failed (offline at launch) is tried again, never skipped
    /// for the rest of the launch — else a live background upload goes twice.
    func testAFailedLookForBackgroundUploadsIsTriedAgain() async {
        queue(["a"])
        backend.backgroundUploads = nil
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.resumeCalls, 1)
        let handle = UploadHandle(cancel: {})
        backend.backgroundUploads = [ResumedUpload(momentID: "b", handle: handle)]
        await outbox.adoptBackgroundUploads()
        XCTAssertEqual(backend.resumeCalls, 2)
        XCTAssertTrue(outbox.uploadsInFlight.contains("b"))
        handle.settle(.failure(CKError(.networkFailure)))
        await waitUntil { self.outbox.uploadsInFlight.isEmpty }
    }

    /// iCloud's copy of a moment this launch is already sending is cancelled, not run twice.
    func testABackgroundCopyOfASendUnderWayIsCancelled() async throws {
        queue(["a"])
        let cancelled = Flag()
        let handle = UploadHandle(cancel: { cancelled.value = true })
        backend.backgroundUploads = [ResumedUpload(momentID: "a", handle: handle)]
        let outbox = outbox!
        let moment = try XCTUnwrap(index.load().first)
        backend.duringSend = { _ in await outbox.adoptBackgroundUploads() }
        try await outbox.upload(moment)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(backend.sent, ["a"])
    }

    /// Unlinked and re-paired mid-upload: landing in the old zone isn't a send to the new one.
    func testALandingAfterThePairingMovedIsNotMarkedSent() async throws {
        queue(["a"])
        let store = store!
        let moment = try XCTUnwrap(index.load().first)
        backend.duringSend = { _ in
            await MainActor.run {
                store.pairing = PairingInfo(role: .participant, zoneName: "OtherZone",
                                            zoneOwnerName: "someone", pairedAt: Fixtures.t0)
            }
        }
        try await outbox.upload(moment)
        XCTAssertEqual(index.load().first?.uploaded, false)
        XCTAssertTrue(confirmed.isEmpty)
    }

    func testAFailedBackgroundUploadStaysPending() async {
        queue(["a"])
        let handle = UploadHandle(cancel: {})
        backend.backgroundUploads = [ResumedUpload(momentID: "a", handle: handle)]
        await outbox.retryPendingUploads(automatic: true)
        handle.settle(.failure(CKError(.networkFailure)))
        await waitUntil { self.outbox.uploadsInFlight.isEmpty }
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertEqual(index.load().first?.uploaded, false)
        await outbox.retryPendingUploads(automatic: true)
        XCTAssertEqual(backend.sent, ["a"], "the next pass sends it itself")
    }
}

/// A flag a `@Sendable` test hook can set.
private final class Flag: @unchecked Sendable {
    var value = false
}

/// Holds a fake upload until the test lets it land.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let go = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if go { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}
