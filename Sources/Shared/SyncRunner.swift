import Foundation
import os

/// What the open app posts after a refresh: the app's `NotificationManager`,
/// a recorder in tests.
@MainActor
protocol SyncNotifier {
    func postPartnerLeft(name: String) async
    func postNudge(from name: String, sentAt: Date?) async
    func postMoment(_ moment: Moment, from name: String) async
    func postRemoval(from name: String, count: Int) async
}

/// The one place that turns "something changed" into updated local state, widget,
/// and — where warranted — a notification, however the refresh was triggered.
/// Visible pushes are already on screen before this runs; `announce` means "the
/// user hasn't been told yet". Its store, backend, notifier and banner upkeep
/// are passed in, so a test runs it over `FakeBackend`.
@MainActor
struct SyncRunner {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "SyncRunner")

    var store: SharedStore = .shared
    var backend: @MainActor () -> any SyncBackend = { Backend.current }
    var notifier: any SyncNotifier
    /// `BannerUpkeep.run` in the app; nothing in a test, which has no delivered banners.
    var upkeep: @MainActor (_ caughtUp: Bool) async -> Void = { await BannerUpkeep.run(caughtUp: $0) }

    /// - Returns: `true` if anything the user would notice changed.
    @discardableResult
    func refresh(announce: Bool = true) async throws -> Bool {
        let previousStatus = store.snapshot.theirs
        let backend = backend()
        let result = try await withDeadline(AppConfig.refreshDeadline) { try await backend.refresh() }

        // Check and claim inside one `mutate`, under the cross-process lock: the service
        // extension advances the same watermarks, and check-then-act outside it double-announced.
        var claims = AnnouncementPolicy.Claims()
        store.mutate(reloadWidgets: false) {
            claims = AnnouncementPolicy.claim(result, previousStatus: previousStatus, in: &$0)
        }
        let name = store.snapshot.moderatedPartnerName
        for post in PushBannerPolicy.appAnnouncements(claims, result: result, announce: announce) {
            switch post {
            case .partnerLeft: await notifier.postPartnerLeft(name: name)
            case .nudge(let sentAt): await notifier.postNudge(from: name, sentAt: sentAt)
            case .moment(let moment): await notifier.postMoment(moment, from: name)
            case .removed(let count): await notifier.postRemoval(from: name, count: count)
            }
        }
        await upkeep(result.isWholeDelta)

        return AnnouncementPolicy.changed(result, previousStatus: previousStatus)
    }

    /// Best-effort variant for a background wake with no model to run it: the
    /// open app re-reads the store when told to.
    func refreshQuietly() async -> Bool {
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
            Self.log.error("Background refresh failed: \(error.localizedDescription)")
            return false
        }
    }
}
