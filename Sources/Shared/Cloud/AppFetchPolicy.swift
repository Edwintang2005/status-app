import Foundation

/// When the open app can skip a change fetch another process just made. Only
/// a *whole* readable delta counts: one batch, or records held unreadable,
/// leaves something for the app to fetch. Pull-to-refresh always fetches.
enum AppFetchPolicy {
    /// Coming to the foreground this soon after a complete fetch (the push's
    /// notification service, the widget, our own) reuses it — only while pushes
    /// reach the service, and every push it started on took a whole delta:
    /// the app has no timer, so anything else waits for the next trigger.
    static let foregroundReuseWindow: TimeInterval = 30
    /// Records owed longer than this don't make every foregrounding fetch: one
    /// nobody can read would otherwise do so for its whole month.
    static let owedRecentlyWindow: TimeInterval = 24 * 60 * 60

    struct Foreground: Equatable {
        var lastSyncedAt: Date?
        var heldSince: Date?
        /// Notifications allowed and shown somewhere, so the service runs per push.
        var pushesArrive: Bool
        /// No token is a resync owed (a cleared or corrupt store).
        var hasChangeToken: Bool
        var lastPushID: String?
        var wholePushID: String?
    }

    static func fetchesOnForeground(_ state: Foreground, now: Date = Date()) -> Bool {
        let owesRecent = state.heldSince.map { now.timeIntervalSince($0) < owedRecentlyWindow } ?? false
        guard state.pushesArrive, state.hasChangeToken, !owesRecent,
              state.lastPushID == nil || state.lastPushID == state.wholePushID,
              let lastSyncedAt = state.lastSyncedAt, lastSyncedAt <= now else { return true }
        return now.timeIntervalSince(lastSyncedAt) >= foregroundReuseWindow
    }

    /// A push shown over the open app: its notification service already took the
    /// whole delta when it stamped this push (`SharedStore.wholePushID`).
    static func fetchesAfterPush(_ identifier: String, wholePushID: String?) -> Bool {
        identifier != wholePushID
    }
}
