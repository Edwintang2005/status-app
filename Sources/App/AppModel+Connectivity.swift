import Foundation
import os
import UIKit

// The app's side of `SyncCoordinator`: what a fetch and the recovery pass do
// here. When they run — launch, foreground, pushes, the network — is the coordinator's.
extension AppModel: SyncHost {
    // MARK: - Entry points (the coordinator's, under the names callers use)

    /// One fetch and the recovery pass after it; returns once a fetch covering
    /// this call has landed (one already running is waited for, then run again).
    func refresh() async { await sync.refresh(asked: true) }
    func refreshOnForeground() async { await sync.foreground() }
    func refreshAfterPush(_ identifier: String) async { await sync.afterPush(identifier) }
    func accountDidChange() async { await sync.accountChanged() }
    func recoverAfterRefresh() async { await sync.recover() }

    // MARK: - SyncHost

    func readinessProblem() async -> String? {
        if case .unavailable(let message) = await backend.readiness() { return message }
        return nil
    }

    func noteAccountChanged() async { await backend.noteAccountChanged() }

    func fetch() async throws {
        try await SyncRunner(store: store, backend: { self.backend }, notifier: AppNotifier()).refresh()
    }

    func fetchLanded() {
        recentStatusesKey = nil
        reload()
    }

    func fetchFailed(_ error: Error) {
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
    }

    func unpairedPass() async { await cleanUpSubscriptionsIfNeeded() }

    func recoveryPass() async {
        await sendQueued(automatic: true)
        await outbox.flushReceipts(automatic: true)
        topUpMedia()
        await checkShareMembers(throttled: true)
        await checkInstalledWidgets()
    }

    func foregroundState() async -> AppFetchPolicy.Foreground? {
        guard let pairing = store.pairing else { return nil }
        return AppFetchPolicy.Foreground(
            lastSyncedAt: store.snapshot.lastSyncedAt,
            heldSince: store.unreadableTally.heldSince,
            pushesArrive: await NotificationManager.servicePushesArrive(),
            hasChangeToken: store.changeToken(for: SharedStore.changeTokenKey(for: pairing.role)) != nil,
            lastPushID: store.lastPushID,
            wholePushID: store.wholePushID)
    }

    var wholePushID: String? { store.wholePushID }
    var fetchThrottled: Bool { store.fetchWaitsOutThrottle() }

    func prefetchRecentMedia() async { await backend.prefetchRecentMedia() }

    /// Downloads, not sends: off the recovery gate, one run at a time.
    private func topUpMedia() {
        guard mediaTopUp == nil else { return }
        mediaTopUp = Task {
            await restoreLatestThumbnailIfMissing()
            await fetchMissingFavourites()
            mediaTopUp = nil
        }
    }

    /// Everything queued, in order. Re-read before the uploads, which can take
    /// a while (each one confirms itself through `noteUploaded`), and after them.
    func sendQueued(automatic: Bool) async {
        var changed = await outbox.republishStatus(automatic: automatic)
        if await outbox.republishAnniversary(automatic: automatic) { changed = true }
        if await outbox.republishAnniversaryRequest(automatic: automatic) { changed = true }
        // Before the upload retry: the clear and a retry never overlap.
        if await outbox.advanceFreshStart(automatic: automatic) { changed = true }
        if changed { reload() }
        if await outbox.retryPendingUploads(automatic: automatic) { reload() }
        // After the uploads: an edit to a moment that just landed can go now.
        if await outbox.republishCaptions(automatic: automatic) { reload() }
        // After the uploads too: one deleted while still sending goes once it lands.
        if await outbox.sendDeletions(automatic: automatic) { reload() }
        sendWhenShareClaimsLapse()
    }

    /// A share-sheet send the passes above stood aside for goes the moment its
    /// claim lapses, not at whatever pass comes next.
    private func sendWhenShareClaimsLapse() {
        let waiting = history.filter { $0.fromMe && !$0.uploaded }.map(\.id) + Array(store.pendingMomentDeletions)
        guard let lapse = ShareIntake.nextLapse(of: waiting, in: store.shareUploadClaims) else { return }
        shareClaimWake?.cancel()
        shareClaimWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, lapse.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            // Woken: a pass scheduling the next wake mustn't cancel this one mid-upload.
            self?.shareClaimWake = nil
            await self?.sendQueued(automatic: true)
        }
    }

    /// Redraws every widget from this phone's copy, even with nothing new: a
    /// reload asked for from the front doesn't count against WidgetKit's
    /// budget, so opening the app frees a widget left on an old timeline (an
    /// outage's failed refreshes) instead of it waiting out its hourly backstop.
    /// - Returns: whether it asked (only from the front).
    @discardableResult
    func redrawWidgets() -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        SharedStore.reloadWidgets()
        return true
    }
}
