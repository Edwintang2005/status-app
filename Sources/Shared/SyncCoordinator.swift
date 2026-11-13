import Foundation
import Network
import Observation
import os

/// What `SyncCoordinator` drives in the app: the fetch, what follows one, and
/// the recovery pass. `AppModel` in the app, a recorder in tests.
@MainActor
protocol SyncHost: AnyObject {
    var isPaired: Bool { get }
    /// Sends still queued: the reconnect catch-up isn't done while there are any.
    var pendingSendCount: Int { get }
    /// iCloud asked us to slow down (`SharedStore.fetchWaitsOutThrottle`): only an asked-for fetch goes.
    var fetchThrottled: Bool { get }
    /// PairingView's iCloud warning, or `nil` when the backend can work.
    func readinessProblem() async -> String?
    /// The system said the iCloud account changed.
    func noteAccountChanged() async
    /// One change fetch and its announcements (`SyncRunner.refresh`).
    func fetch() async throws
    func fetchLanded()
    func fetchFailed(_ error: Error)
    /// Unpaired, there's nothing to fetch; old subscriptions may still want clearing.
    func unpairedPass() async
    /// Republishes, retries, receipts and the like (`AppModel.recoveryPass`).
    func recoveryPass() async
    /// The foreground's reuse decision's inputs (`AppFetchPolicy`); `nil` unpaired.
    func foregroundState() async -> AppFetchPolicy.Foreground?
    var wholePushID: String? { get }
    func prefetchRecentMedia() async
    @discardableResult func redrawWidgets() -> Bool
}

/// When the app fetches, and what runs after: launch, foregrounding, pushes,
/// the network coming back and an account change all come here. One fetch at a
/// time and one recovery pass at a time (`RunGate`), each caller's rule named;
/// readiness reused within `readinessReuseWindow`. Pure sequencing — the
/// effects are the host's — so it runs under `make test`.
@MainActor
@Observable
final class SyncCoordinator {
    @ObservationIgnored weak var host: (any SyncHost)?
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.appGroupID, category: "SyncCoordinator")
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void

    let fetchGate = RunGate()
    let recoveryGate = RunGate()
    @ObservationIgnored let readinessGate = RunGate()

    var isRefreshing: Bool { fetchGate.isRunning }
    /// Non-nil when the backend can't work — no iCloud account, and so on.
    private(set) var readinessMessage: String?
    @ObservationIgnored private(set) var readinessCheckedAt: Date?
    /// Whichever fetch last worked — the reconnect catch-up judges by it, not by who ran it.
    @ObservationIgnored private(set) var lastFetchSucceededAt: Date?
    /// The last fetch failed: the next to succeed redraws the widgets.
    @ObservationIgnored private(set) var fetchFailing = false
    /// Someone asked for a fetch (pull-to-refresh) that hasn't run yet.
    @ObservationIgnored private var askedPending = false

    /// No network path — display only (Home's card, the gallery's wording). Sends
    /// never gate on it: it goes stale while suspended, and a banner action wakes
    /// the app before the monitor catches up. They try, and fail quietly offline.
    private(set) var isOffline = false
    /// The path is down because mobile data is off for this app — the one cause the user can fix.
    private(set) var mobileDataDenied = false
    /// Demo mode never touches the network: its card would be a lie.
    @ObservationIgnored private let ignoresNetwork: Bool
    /// Starts `true` so the monitor's immediate first callback doesn't double up with launch's fetch.
    @ObservationIgnored private(set) var networkWasSatisfied = true
    @ObservationIgnored private var offlineShowTask: Task<Void, Never>?
    @ObservationIgnored private(set) var catchUpTask: Task<Void, Never>?
    /// The recovery pass the last fetch started — one per fetch, however many
    /// callers shared it; the catch-up waits on it rather than starting another.
    @ObservationIgnored private(set) var recoveryAfterFetch: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    init(ignoresNetwork: Bool = false,
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.ignoresNetwork = ignoresNetwork
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Readiness

    /// Re-checked on every foregrounding, not just launch — the fix happens in
    /// the Settings app, so the user returns expecting it noticed. Callers
    /// arriving mid-check share its answer — unless `fresh`: one begun before an
    /// account change can't answer for after it.
    func checkReadiness(fresh: Bool = false) async {
        await readinessGate.run(fresh ? .joinAndRerun : .join) { [weak self] in
            guard let self, let host = self.host else { return false }
            self.readinessMessage = await host.readinessProblem()
            self.readinessCheckedAt = self.now()
            return true
        }
    }

    private func checkReadinessIfStale() async {
        guard now().timeIntervalSince(readinessCheckedAt ?? .distantPast) >= AppConfig.readinessReuseWindow else { return }
        await checkReadiness()
    }

    // MARK: - Fetching

    /// One fetch, then the recovery pass on its own (pull-to-refresh doesn't wait
    /// on uploads). Returns once a fetch that covers this call has landed —
    /// `.joinAndRerun` by default: whatever prompted it may postdate the one in flight.
    /// `asked`: pull-to-refresh, which goes even while iCloud asked us to slow down.
    /// - Returns: whether a fetch worked.
    @discardableResult
    func refresh(_ arrival: RunGate.Arrival = .joinAndRerun, asked: Bool = false) async -> Bool {
        // Held here, not in the pass: a later caller's queued rerun replaces an asked one's.
        if asked { askedPending = true }
        return await fetchGate.run(arrival) { [weak self] in await self?.fetchOnce() ?? false } ?? false
    }

    /// A fetch of the caller's own (Diagnostics' resync), only if none is running.
    /// - Returns: `nil` when one was.
    func exclusiveFetch(_ pass: @escaping @MainActor () async -> Bool) async -> Bool? {
        await fetchGate.run(.skipIfBusy, pass)
    }

    private func fetchOnce() async -> Bool {
        guard let host else { return false }
        let asked = askedPending
        askedPending = false
        // Re-checked when paired too: this is what notices an iCloud account
        // switch (which drops the reused answer). One just asked is reused.
        await checkReadinessIfStale()
        guard host.isPaired else {
            await host.unpairedPass()
            return false
        }
        // Retrying sooner can extend the throttle; nothing fails, so nothing is redrawn as failing.
        guard asked || !host.fetchThrottled else {
            log.notice("iCloud asked us to slow down; skipping this automatic fetch.")
            return false
        }
        do {
            try await host.fetch()
            lastFetchSucceededAt = now()
            host.fetchLanded()
            if fetchFailing {
                fetchFailing = false
                host.redrawWidgets()
            }
            // A fetch that worked is proof the monitor's "down" is stale.
            offlineShowTask?.cancel()
            setOffline(false)
            // Started here, once per fetch — not by each caller that shared it.
            recoveryAfterFetch = Task { await self.recover() }
            return true
        } catch {
            fetchFailing = true
            host.fetchFailed(error)
            return false
        }
    }

    /// The recovery pass: one at a time, and a pass asked for mid-pass runs once more.
    func recover(_ arrival: RunGate.Arrival = .joinAndRerun) async {
        guard let host, host.isPaired else { return }
        await recoveryGate.run(arrival) { [weak host] in
            await host?.recoveryPass()
            return true
        }
    }

    // MARK: - Triggers

    /// Launch's fetch. The scene turning active asks too: they share one fetch,
    /// and the recovery pass runs either way.
    func launch() async {
        await checkReadiness()
        guard let host, host.isPaired else { return }
        if let fetched = lastFetchSucceededAt,
           now().timeIntervalSince(fetched) < AppConfig.launchRefreshCoalesceWindow {
            Task { await self.recover() }
        } else {
            await refresh(.join)
        }
    }

    /// The scene came to the foreground. A complete fetch by any process moments
    /// ago is reused (`AppFetchPolicy`); readiness and the queued sends still run.
    /// Joins a fetch already running rather than queueing another: coming to the
    /// front says nothing changed since it began (launch and `.active` fire together).
    func foreground() async {
        guard let host, let state = await host.foregroundState() else {
            await refresh(.join)
            return
        }
        guard !AppFetchPolicy.fetchesOnForeground(state, now: now()) else {
            await refresh(.join)
            return
        }
        await checkReadinessIfStale()
        await recover()
    }

    /// A push shown over the open app. The service extension may have taken one
    /// batch of it: fetch the rest — unless it took the whole delta, when what
    /// a fetch brings along still runs: the recovery pass and full-size media.
    func afterPush(_ identifier: String) async {
        guard let host, host.isPaired,
              !AppFetchPolicy.fetchesAfterPush(identifier, wholePushID: host.wholePushID) else {
            await refresh()
            return
        }
        Task { await self.recover() }
        await host.prefetchRecentMedia()
    }

    /// The system reported an iCloud account change: the next readiness check
    /// looks the account up for real, then a fetch.
    func accountChanged() async {
        await host?.noteAccountChanged()
        await checkReadiness(fresh: true)
        await refresh()
    }

    // MARK: - Network

    /// Refreshes on the offline→online edge. Delivered on the main queue so
    /// updates apply in the order they happened.
    func startMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.pathChanged(down: path.status == .unsatisfied,
                                  cellularDenied: path.unsatisfiedReason == .cellularDenied)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Only `.unsatisfied` is down: `.requiresConnection` (an on-demand VPN, a
    /// dormant radio) comes up as soon as something uses it. Path churn while
    /// up is ignored; only the edge back up fetches.
    func pathChanged(down: Bool, cellularDenied: Bool) {
        let cameBackOnline = !down && !networkWasSatisfied
        networkWasSatisfied = !down
        offlineShowTask?.cancel()
        if down {
            mobileDataDenied = cellularDenied
            // Shown after a moment: a Wi-Fi↔cellular handoff blips for under a second.
            offlineShowTask = Task { [weak self] in
                await self?.sleep(AppConfig.offlineCardDelay)
                guard !Task.isCancelled, let self, !self.networkWasSatisfied else { return }
                self.setOffline(true)
            }
        } else {
            setOffline(false)
        }
        if cameBackOnline {
            log.notice("Network is back; refreshing.")
            catchUpTask?.cancel()
            catchUpTask = Task { [weak self] in await self?.catchUpAfterReconnect() }
        }
    }

    private func setOffline(_ offline: Bool) {
        guard !ignoresNetwork, isOffline != offline else { return }
        isOffline = offline
    }

    /// The first fetch after the path returns often beats DNS or a VPN: it's
    /// tried again on `reconnectRetryDelays` until one since the edge works
    /// (whoever ran it). After that what's left is a send that hit the flap,
    /// so later tries re-send rather than fetch again — done once nothing's queued.
    func catchUpAfterReconnect() async {
        let since = now()
        for delay in AppConfig.reconnectRetryDelays {
            if delay > 0 { await sleep(delay) }
            guard !Task.isCancelled, networkWasSatisfied, let host, host.isPaired else { return }
            if let fetched = lastFetchSucceededAt, fetched >= since {
                await recover()
            } else if await refresh() {
                // The pass that fetch started, not a second one.
                await recoveryAfterFetch?.value
            }
            if let fetched = lastFetchSucceededAt, fetched >= since, host.pendingSendCount == 0 { return }
        }
    }
}
