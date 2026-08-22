import Foundation
import os

/// The one place that turns "something changed in CloudKit" into updated local
/// state, a refreshed widget, and — when the partner has nudged — a
/// notification. Called from the UI, from foregrounding, and from silent
/// pushes, so the behaviour is identical however the refresh was triggered.
@MainActor
enum SyncRunner {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "SyncRunner")

    /// - Returns: `true` if anything about the partner's status changed.
    @discardableResult
    static func refresh(announceNudges: Bool = true) async throws -> Bool {
        let store = SharedStore.shared
        let before = store.snapshot.theirs

        guard let theirs = try await CloudSync.shared.fetchStatuses() else { return false }

        if announceNudges, theirs.nudgeCount > store.snapshot.lastSeenPartnerNudgeCount {
            let name = store.snapshot.partnerDisplayName
            store.mutate(reloadWidgets: false) { $0.lastSeenPartnerNudgeCount = theirs.nudgeCount }
            await NotificationManager.postNudge(from: name)
        } else if theirs.nudgeCount > store.snapshot.lastSeenPartnerNudgeCount {
            store.mutate(reloadWidgets: false) { $0.lastSeenPartnerNudgeCount = theirs.nudgeCount }
        }

        return before != theirs
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
