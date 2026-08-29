import Foundation
import os

/// The one place that turns "something changed" into updated local state, a
/// refreshed widget, and — where warranted — a notification. Called from the
/// UI, from foregrounding, and from background pushes, so behaviour is
/// identical however the refresh was triggered.
///
/// Note that visible pushes are delivered by CloudKit itself and are *already
/// on screen* before this runs. `announce` is how the caller says "the user
/// has not been told yet".
@MainActor
enum SyncRunner {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "SyncRunner")

    /// - Returns: `true` if anything the user would notice changed.
    @discardableResult
    static func refresh(announce: Bool = true) async throws -> Bool {
        let store = SharedStore.shared
        let previousStatus = store.snapshot.theirs

        let result = try await Backend.current.refresh()

        // The check and the write happen inside one `mutate`, under the
        // cross-process lock: the notification service extension advances the
        // same watermarks, and a check-then-act outside the lock let both
        // processes decide to announce the same nudge.
        if let theirs = result.partnerStatus {
            var shouldAnnounceNudge = false
            store.mutate(reloadWidgets: false) { snapshot in
                guard theirs.nudgeCount > snapshot.lastSeenPartnerNudgeCount else { return }
                snapshot.lastSeenPartnerNudgeCount = theirs.nudgeCount
                // The first time this device ever sees the partner's status —
                // pairing into an existing zone, or a bootstrap refresh that
                // failed and seeded the watermark to 0 — any standing count is
                // history, not a fresh tap. Adopt it silently.
                shouldAnnounceNudge = previousStatus != nil
            }
            if announce, shouldAnnounceNudge {
                let name = store.snapshot.partnerDisplayName
                await NotificationManager.postNudge(from: name, sentAt: theirs.lastNudgeAt)
            }
        }

        // Announce only the newest, even if several arrived at once — a stack
        // of banners for one sync is worse than one.
        if let moment = result.newestPartnerMoment {
            var shouldAnnounceMoment = false
            store.mutate(reloadWidgets: false) { snapshot in
                guard !snapshot.hasAnnounced(moment.id) else { return }
                snapshot.recordAnnounced(moment.id)
                shouldAnnounceMoment = true
            }
            if announce, shouldAnnounceMoment {
                let name = store.snapshot.partnerDisplayName
                await NotificationManager.postMoment(moment, from: name)
            }
        }

        let changed = previousStatus != result.partnerStatus || !result.newPartnerMoments.isEmpty
        if changed {
            // A push-driven refresh updates the store and widget, but the
            // open app's model has its own copy of the snapshot — without
            // this, a foregrounded HomeView shows the old status until the
            // user pulls to refresh or re-foregrounds.
            NotificationCenter.default.post(name: .pairingDidChange, object: nil)
        }
        return changed
    }

    /// Best-effort variant for background wake-ups, where throwing is pointless.
    static func refreshQuietly() async -> Bool {
        do {
            return try await refresh()
        } catch SyncError.linkEnded {
            // The refresh already erased local state; tell the open app so it
            // both re-reads the store (snapping to the pairing screen) and
            // says why, instead of silently ejecting the user.
            NotificationCenter.default.post(name: .pairingDidChange, object: nil)
            NotificationCenter.default.post(name: .pairingDidFail,
                                            object: SyncError.linkEnded.errorDescription)
            return true
        } catch {
            log.error("Background refresh failed: \(error.localizedDescription)")
            return false
        }
    }
}
