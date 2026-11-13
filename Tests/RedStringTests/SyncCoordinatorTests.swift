import XCTest

/// When the app fetches and what runs after (`SyncCoordinator`, `RunGate`,
/// `SyncRunner`): one fetch at a time with each caller's rule kept, launch and
/// foregrounding sharing one, the reconnect catch-up re-sending rather than
/// re-fetching, and a refresh's announcements taken from the owed list.
@MainActor
final class SyncCoordinatorTests: XCTestCase {
    /// Holds a pass open until released.
    @MainActor
    final class Latch {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var waiting = 0
        private var released = false
        func wait() async {
            guard !released else { return }
            waiting += 1
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() {
            released = true
            continuations.forEach { $0.resume() }
            continuations = []
        }
    }

    final class Host: SyncHost {
        var isPaired = true
        var pendingSendCount = 0
        var fetches = 0
        var recoveries = 0
        var readinessChecks = 0
        var redraws = 0
        var unpairedPasses = 0
        var fetchError: Error?
        var latch: Latch?
        var foreground: AppFetchPolicy.Foreground?
        var wholePushID: String?
        var fetchThrottled = false

        var readinessLatch: Latch?
        func readinessProblem() async -> String? {
            readinessChecks += 1
            await readinessLatch?.wait()
            return nil
        }
        func noteAccountChanged() async {}
        func fetch() async throws {
            fetches += 1
            await latch?.wait()
            if let fetchError { throw fetchError }
        }
        func fetchLanded() {}
        func fetchFailed(_ error: Error) {}
        func unpairedPass() async { unpairedPasses += 1 }
        func recoveryPass() async {
            recoveries += 1
            pendingSendCount = max(0, pendingSendCount - 1)
        }
        func foregroundState() async -> AppFetchPolicy.Foreground? { foreground }
        func prefetchRecentMedia() async {}
        func redrawWidgets() -> Bool { redraws += 1; return true }
    }

    /// Counts the coordinator's waits that ran to their end.
    @MainActor final class Sleeps { var finished = 0 }

    private var host: Host!
    private var sync: SyncCoordinator!
    private var sleeps: Sleeps!

    override func setUp() async throws {
        host = Host()
        let sleeps = Sleeps()
        self.sleeps = sleeps
        sync = SyncCoordinator(sleep: { _ in
            await Task.yield()
            sleeps.finished += 1
        })
        sync.host = host
    }

    // MARK: RunGate

    func testAJoinerWaitsForTheRunAndAReRunnerGetsItsOwnPass() async {
        let gate = RunGate()
        let latch = Latch()
        var log: [String] = []
        let first = Task { await gate.run(.join) { log.append("first"); await latch.wait(); return true } }
        await waitUntil { latch.waiting == 1 }
        let joiner = Task { await gate.run(.join) { log.append("joiner"); return true } }
        let rerun = Task { await gate.run(.joinAndRerun) { log.append("rerun"); return false } }
        let skipped = await gate.run(.skipIfBusy) { log.append("skipped"); return true }
        XCTAssertNil(skipped)
        latch.release()

        let firstResult = await first.value
        let joinerResult = await joiner.value
        let rerunResult = await rerun.value
        XCTAssertEqual(firstResult, true)
        XCTAssertEqual(joinerResult, true, "the joiner takes the run's answer")
        XCTAssertEqual(rerunResult, true)
        XCTAssertEqual(log, ["first", "rerun"], "the re-runner's own pass, once; nobody else's")
        XCTAssertFalse(gate.isRunning)
    }

    // MARK: Fetching

    /// iCloud asked us to slow down: automatic fetches wait it out, without
    /// counting as failures; pull-to-refresh still goes.
    func testAThrottleHoldsAutomaticFetchesButNotAnAskedOne() async {
        host.fetchThrottled = true
        let automatic = await sync.refresh()
        XCTAssertFalse(automatic)
        XCTAssertEqual(host.fetches, 0)
        XCTAssertFalse(sync.fetchFailing)

        let asked = await sync.refresh(asked: true)
        XCTAssertTrue(asked)
        XCTAssertEqual(host.fetches, 1)
    }

    /// Launch and the scene turning active fire together: one fetch, one readiness look.
    func testLaunchAndForegroundShareOneFetch() async {
        let latch = Latch()
        host.latch = latch
        let launch = Task { await sync.launch() }
        await waitUntil { latch.waiting == 1 }
        let foreground = Task { await sync.foreground() }
        latch.release()
        await launch.value
        await foreground.value
        XCTAssertEqual(host.fetches, 1)
        XCTAssertEqual(host.readinessChecks, 1)
        await sync.recoveryAfterFetch?.value
        XCTAssertEqual(host.recoveries, 1, "one fetch, one recovery pass — not one per caller")
    }

    /// An account change can't take the answer of a readiness look begun before it.
    func testAnAccountChangeForcesItsOwnReadinessLook() async {
        let latch = Latch()
        host.readinessLatch = latch
        let before = Task { await sync.checkReadiness() }
        await waitUntil { latch.waiting == 1 }
        let changed = Task { await sync.accountChanged() }
        await waitUntil { self.sync.readinessGate.isRerunQueued }
        latch.release()
        await before.value
        await changed.value
        XCTAssertEqual(host.readinessChecks, 2, "the look begun before the change doesn't answer for after it")
    }

    /// A push mid-fetch may postdate it: the fetch runs once more, and the push's
    /// caller returns only after that.
    func testAPushMidFetchFetchesOnceMoreAndWaitsForIt() async {
        let latch = Latch()
        host.latch = latch
        let first = Task { await sync.refresh() }
        await waitUntil { latch.waiting == 1 }
        let push = Task { await sync.afterPush("push-1") }
        await waitUntil { self.sync.fetchGate.isRerunQueued }
        latch.release()
        await push.value
        XCTAssertEqual(host.fetches, 2, "returned only once a fetch covering the push landed")
        _ = await first.value
    }

    /// The network back with a send queued: one fetch, then re-sends — never a
    /// fetch per retry delay.
    func testTheReconnectCatchUpFetchesOnceThenResends() async {
        host.pendingSendCount = 3
        await sync.catchUpAfterReconnect()
        XCTAssertEqual(host.fetches, 1)
        XCTAssertGreaterThanOrEqual(host.recoveries, 2)
    }

    /// Nothing queued: done after the first good fetch.
    func testTheReconnectCatchUpStopsOnceFetchedWithNothingQueued() async {
        await sync.catchUpAfterReconnect()
        XCTAssertEqual(host.fetches, 1)
        XCTAssertEqual(host.recoveries, 1, "waits on the fetch's own pass rather than starting another")
    }

    func testAFetchThatWorksAgainRedrawsTheWidgetsOnce() async {
        host.fetchError = CancellationError()
        await sync.refresh()
        XCTAssertEqual(host.redraws, 0)
        host.fetchError = nil
        await sync.refresh()
        await sync.refresh()
        XCTAssertEqual(host.redraws, 1, "an outage's stale timeline, freed once")
    }

    func testUnpairedThereIsNothingToFetch() async {
        host.isPaired = false
        await sync.refresh()
        XCTAssertEqual(host.fetches, 0)
        XCTAssertEqual(host.unpairedPasses, 1)
    }

    // MARK: The network

    /// A Wi-Fi↔cellular blip never shows the offline card; a real drop does, and
    /// coming back fetches.
    func testTheOfflineCardWaitsOutABlipAndTheEdgeBackFetches() async {
        sync.pathChanged(down: true, cellularDenied: false)
        sync.pathChanged(down: false, cellularDenied: false)
        await waitUntil { self.sleeps.finished == 1 }
        XCTAssertFalse(sync.isOffline, "the card's wait ended with the network back")

        sync.pathChanged(down: true, cellularDenied: true)
        await waitUntil { self.sync.isOffline }
        XCTAssertTrue(sync.mobileDataDenied)
        let before = host.fetches
        sync.pathChanged(down: false, cellularDenied: false)
        XCTAssertFalse(sync.isOffline)
        await sync.catchUpTask?.value
        XCTAssertGreaterThan(host.fetches, before)
    }

    // MARK: SyncRunner

    /// A sweep a failed batch cut short: what it filed is announced, then it
    /// throws — the fetch didn't finish, so nobody reads it as one that did.
    func testAnInterruptedSweepAnnouncesThenFails() async throws {
        final class Notifier: SyncNotifier {
            var moments: [String] = []
            func postPartnerLeft(name: String) async {}
            func postNudge(from name: String, sentAt: Date?) async {}
            func postMoment(_ moment: Moment, from name: String) async { moments.append(moment.id) }
            func postRemoval(from name: String, count: Int) async {}
        }
        let store = SharedStore(defaults: temporaryDefaults())
        store.mutate { $0.owe([Fixtures.moment("p1")]) }
        let backend = FakeBackend()
        var cut = RefreshResult.empty
        cut.incomplete = true
        cut.interrupted = true
        backend.refreshResult = cut
        let notifier = Notifier()
        let runner = SyncRunner(store: store, backend: { backend }, notifier: notifier, upkeep: { _ in })

        do {
            try await runner.refresh()
            XCTFail("an interrupted sweep isn't a finished fetch")
        } catch SyncError.sweepInterrupted {}
        XCTAssertEqual(notifier.moments, ["p1"], "announced all the same")
        XCTAssertEqual(backend.refreshes, 1, "one pass: the rest waits for the next refresh")
    }

    /// A pull-to-refresh queued behind a fetch iCloud throttled still runs, though
    /// an automatic caller queued after it replaces the rerun.
    func testAnAskedFetchSurvivesALaterAutomaticRerun() async {
        let latch = Latch()
        host.latch = latch
        let first = Task { await sync.refresh() }
        await waitUntil { latch.waiting == 1 }
        host.fetchThrottled = true
        let asked = Task { await sync.refresh(asked: true) }
        await waitUntil { sync.fetchGate.isRerunQueued }
        let automatic = Task { await sync.refresh() }
        host.latch = nil
        latch.release()
        _ = await (first.value, asked.value, automatic.value)
        XCTAssertEqual(host.fetches, 2, "the asked rerun went despite the throttle")
    }

    /// A refresh announces what's owed — once — and only when asked to.
    func testARefreshAnnouncesTheOwedMomentOnce() async throws {
        final class Notifier: SyncNotifier {
            var moments: [String] = []
            func postPartnerLeft(name: String) async {}
            func postNudge(from name: String, sentAt: Date?) async {}
            func postMoment(_ moment: Moment, from name: String) async { moments.append(moment.id) }
            func postRemoval(from name: String, count: Int) async {}
        }
        let store = SharedStore(defaults: temporaryDefaults())
        store.mutate { $0.owe([Fixtures.moment("p1")]) }
        let notifier = Notifier()
        let backend = FakeBackend()
        let runner = SyncRunner(store: store, backend: { backend }, notifier: notifier, upkeep: { _ in })

        try await runner.refresh(announce: false)
        XCTAssertTrue(notifier.moments.isEmpty, "a visible push already said it")
        XCTAssertTrue(store.snapshot.owedMoments.isEmpty, "but it's taken all the same")

        store.mutate { $0.owe([Fixtures.moment("p2")]) }
        try await runner.refresh()
        try await runner.refresh()
        XCTAssertEqual(notifier.moments, ["p2"])
    }
}
