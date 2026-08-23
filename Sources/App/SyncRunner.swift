import Foundation
import os

/// The one place that turns "something changed" into updated local state, a
/// refreshed widget, and — where warranted — a notification. Called from the
/// UI, from foregrounding, and from silent pushes, so behaviour is identical
/// however the refresh was triggered.
///
/// Note that visible pushes for nudges and moments are delivered by CloudKit
/// itself and are *already on screen* before this runs. `announce` is how the
/// caller says "the user has not been told yet".
@MainActor
enum SyncRunner {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "SyncRunner")

    /// - Returns: `true` if anything the user would notice changed.
    @discardableResult
    static func refresh(announce: Bool = true) async throws -> Bool {
        let store = SharedStore.shared
        let previousStatus = store.snapshot.theirs

        let result = try await Backend.current.refresh()

        if let theirs = result.partnerStatus,
           theirs.nudgeCount > store.snapshot.lastSeenPartnerNudgeCount {
            let name = store.snapshot.partnerDisplayName
            store.mutate(reloadWidgets: false) { $0.lastSeenPartnerNudgeCount = theirs.nudgeCount }
            if announce { await NotificationManager.postNudge(from: name) }
        }

        // Announce only the newest, even if several arrived at once — a stack
        // of banners for one sync is worse than one.
        if let moment = result.newestPartnerMoment, store.snapshot.lastNotifiedMomentID != moment.id {
            let name = store.snapshot.partnerDisplayName
            store.mutate(reloadWidgets: false) { $0.lastNotifiedMomentID = moment.id }
            if announce { await NotificationManager.postMoment(moment, from: name) }
        }

        return previousStatus != result.partnerStatus || !result.newPartnerMoments.isEmpty
    }

    /// Best-effort variant for background wake-ups, where throwing is pointless.
    static func refreshQuietly() async -> Bool {
        do {
            return try await refresh()
        } catch {
            log.error("Background refresh failed: \(error.localizedDescription)")
            return false
        }
    }
}
