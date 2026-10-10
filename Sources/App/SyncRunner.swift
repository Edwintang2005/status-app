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

        let result = try await withDeadline(AppConfig.refreshDeadline) { try await Backend.current.refresh() }

        // Check and claim inside one `mutate`, under the cross-process lock: the service
        // extension advances the same watermarks, and check-then-act outside it double-announced.
        var claims = AnnouncementPolicy.Claims()
        store.mutate(reloadWidgets: false) {
            claims = AnnouncementPolicy.claim(result, previousStatus: previousStatus, in: &$0)
        }
        let name = store.snapshot.moderatedPartnerName
        for post in PushBannerPolicy.appAnnouncements(claims, result: result, announce: announce) {
            switch post {
            case .partnerLeft: await NotificationManager.postPartnerLeft(name: name)
            case .nudge(let sentAt): await NotificationManager.postNudge(from: name, sentAt: sentAt)
            case .moment(let moment): await NotificationManager.postMoment(moment, from: name)
            }
        }

        return AnnouncementPolicy.changed(result, previousStatus: previousStatus)
    }

    /// Best-effort variant for background wake-ups, where throwing is pointless.
    /// The model's own refreshes re-read the store themselves; this one tells it to.
    static func refreshQuietly() async -> Bool {
        do {
            let changed = try await refresh()
            // A re-read only: this *is* the refresh, so asking for another finds nothing.
            if changed { NotificationCenter.default.post(name: .snapshotDidChange, object: nil) }
            return changed
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
