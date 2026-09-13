import Foundation
import os

/// The one place that turns "something changed" into updated local state, widget,
/// and — where warranted — a notification, however the refresh was triggered.
/// Visible pushes are already on screen before this runs; `announce` means "the user hasn't been told yet".
@MainActor
enum SyncRunner {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "SyncRunner")

    /// - Returns: `true` if anything the user would notice changed.
    @discardableResult
    static func refresh(announce: Bool = true) async throws -> Bool {
        let store = SharedStore.shared
        let previousStatus = store.snapshot.theirs

        let result = try await Backend.current.refresh()

        // Check and claim inside one `mutate`, under the cross-process lock: the service
        // extension advances the same watermarks, and check-then-act outside it double-announced.
        var claims = AnnouncementPolicy.Claims()
        store.mutate(reloadWidgets: false) {
            claims = AnnouncementPolicy.claim(result, previousStatus: previousStatus, in: &$0)
        }
        if announce {
            let name = store.snapshot.moderatedPartnerName
            if claims.nudge {
                await NotificationManager.postNudge(from: name, sentAt: result.partnerStatus?.lastNudgeAt)
            }
            if let moment = claims.moment {
                await NotificationManager.postMoment(moment, from: name)
            }
        }

        let changed = AnnouncementPolicy.changed(result, previousStatus: previousStatus)
        if changed {
            // The open app's model has its own snapshot copy — without this,
            // HomeView keeps the old status until the next foreground. A re-read
            // only: this *is* the refresh, so asking for another finds nothing.
            NotificationCenter.default.post(name: .snapshotDidChange, object: nil)
        }
        return changed
    }

    /// Best-effort variant for background wake-ups, where throwing is pointless.
    static func refreshQuietly() async -> Bool {
        do {
            return try await refresh()
        } catch SyncError.linkEnded {
            // Local state is already erased; tell the open app to re-read the
            // store and say why, instead of silently ejecting the user.
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
