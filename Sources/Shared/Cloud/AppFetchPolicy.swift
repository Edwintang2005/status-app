import Foundation

/// When the open app can skip a change fetch another process just made. Only
/// a *whole* readable delta counts: one batch, or records held unreadable,
/// leaves something for the app to fetch. Pull-to-refresh always fetches.
enum AppFetchPolicy {
    /// Coming to the foreground this soon after a complete fetch (the push's
    /// notification service, the widget, our own) reuses it: anything newer
    /// would have pushed, and a dropped push costs at most this long.
    static let foregroundReuseWindow: TimeInterval = 30

    static func fetchesOnForeground(lastSyncedAt: Date?, heldSince: Date?, now: Date = Date()) -> Bool {
        guard heldSince == nil, let lastSyncedAt, lastSyncedAt <= now else { return true }
        return now.timeIntervalSince(lastSyncedAt) >= foregroundReuseWindow
    }

    /// A push shown over the open app: its notification service already took the
    /// whole delta when it stamped this push (`SharedStore.wholePushID`).
    static func fetchesAfterPush(_ identifier: String, wholePushID: String?) -> Bool {
        identifier != wholePushID
    }
}
