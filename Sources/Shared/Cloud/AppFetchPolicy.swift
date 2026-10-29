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
        guard state.pushesArrive, state.hasChangeToken, state.heldSince == nil,
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
