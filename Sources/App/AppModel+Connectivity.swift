import Foundation
import Network
import os

// Readiness, the network path, and the refresh with its recovery pass.
extension AppModel {
    // MARK: - Sync

    /// PairingView's iCloud warning. Re-checked on every foregrounding, not just
    /// launch — the fix happens in the Settings app, so the user returns expecting it noticed.
    func refreshReadiness() async {
        if case .unavailable(let message) = await backend.readiness() {
            readinessMessage = message
        } else {
            readinessMessage = nil
        }
        readinessCheckedAt = Date()
    }

    /// Refreshes on the offline→online edge — `refresh()` already handles
    /// offline calls and re-entrancy; the job here is ignoring path churn while up.
    /// Delivered on the main queue so updates apply in the order they happened.
    func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.networkPathChanged(path) }
        }
        pathMonitor.start(queue: .main)
    }

    /// Only `.unsatisfied` is down: `.requiresConnection` (an on-demand VPN, a
    /// dormant radio) comes up as soon as something uses it.
    private func networkPathChanged(_ path: NWPath) {
        let down = path.status == .unsatisfied
        let cameBackOnline = !down && !networkWasSatisfied
        networkWasSatisfied = !down
        offlineShowTask?.cancel()
        if down {
            mobileDataDenied = path.unsatisfiedReason == .cellularDenied
            // Shown after a moment: a Wi-Fi↔cellular handoff blips for under a second.
            offlineShowTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(AppConfig.offlineCardDelay))
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
        #if DEBUG
        // Demo mode's backend never touches the network.
        if DemoMode.isActive { return }
        #endif
        if isOffline != offline { isOffline = offline }
    }

    /// The first refresh after the path returns often beats DNS or a VPN; one
    /// failure must not leave queued sends waiting for the next foreground.
    /// Done once a fetch since the edge worked (whoever ran it — a request that
    /// joined a running refresh still retries if that one failed) and nothing is
    /// left queued: a send pass can still hit the flap after a good fetch.
    private func catchUpAfterReconnect() async {
        let since = Date()
        for delay in AppConfig.reconnectRetryDelays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, networkWasSatisfied, isPaired else { return }
            await refresh()
            if let fetched = lastFetchSucceededAt, fetched >= since, pendingSendCount == 0 { return }
        }
    }

    /// The system reported an iCloud account change: make the next readiness
    /// check look the account up for real, then refresh.
    func accountDidChange() async {
        await backend.noteAccountChanged()
        readinessCheckedAt = nil
        await refresh()
    }

    /// Returns once the fetch lands; the recovery pass it unlocks runs on after,
    /// so pull-to-refresh doesn't wait on uploads.
    func refresh(noteIfBusy: Bool = true) async {
        guard refreshGate.begin(noteIfBusy: noteIfBusy) else { return }
        var fetched = false
        repeat {
            if await fetchOnce() { fetched = true }
        } while refreshGate.takeRequest()
        refreshGate.end()
        // A working refresh is the recovery moment for sends that died offline.
        if fetched {
            Task { await recoverAfterRefresh() }
        }
    }

    /// Coalesced like the fetch: a pass asked for mid-pass runs once more.
    func recoverAfterRefresh() async {
        guard isPaired, recoveryGate.begin() else { return }
        repeat {
            await sendQueued(automatic: true)
            await outbox.flushReceipts()
            await restoreLatestThumbnailIfMissing()
            await checkShareMembers(throttled: true)
            await checkInstalledWidgets()
        } while recoveryGate.takeRequest()
        recoveryGate.end()
    }

    /// Everything queued, in order. Re-read before the uploads, which can take
    /// a while (each one confirms itself through `noteUploaded`), and after them.
    func sendQueued(automatic: Bool) async {
        var changed = await outbox.republishStatus(automatic: automatic)
        if await outbox.republishAnniversary(automatic: automatic) { changed = true }
        if await outbox.republishAnniversaryRequest(automatic: automatic) { changed = true }
        // Before the upload retry: the clear and a retry never overlap.
        if await outbox.advanceFreshStart() { changed = true }
        if changed { reload() }
        if await outbox.retryPendingUploads(automatic: automatic) { reload() }
    }

    /// One fetch and reload; `false` when it failed or there was nothing to fetch for.
    private func fetchOnce() async -> Bool {
        // Re-checked when paired too: this is what notices an iCloud account
        // switch (which drops the reused answer). One just asked is reused.
        if Date().timeIntervalSince(readinessCheckedAt ?? .distantPast) >= AppConfig.readinessReuseWindow {
            await refreshReadiness()
        }
        guard isPaired else {
            await cleanUpSubscriptionsIfNeeded()
            return false
        }
        do {
            try await SyncRunner.refresh()
            recentStatusesKey = nil
            reload()
            lastFetchSucceededAt = Date()
            // A fetch that worked is proof the monitor's "down" is stale.
            offlineShowTask?.cancel()
            setOffline(false)
            return true
        } catch {
            // The backend may have unlinked us (a vanished zone means the other
            // person ended things), so re-read local state either way.
            reload()
            if let sync = error as? SyncError, case .linkEnded = sync {
                // The one refresh failure that is really a message from another person.
                errorTitle = String(localized: "Link ended")
                errorMessage = sync.errorDescription
            }
            // Other refresh failures are routine; the "Synced …" footer already shows staleness.
            log.error("Refresh failed: \(error.localizedDescription)")
            return false
        }
    }
}
