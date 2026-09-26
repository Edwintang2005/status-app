import Foundation

/// When the widget next runs its own refresh. Nothing reloads a widget on
/// unlock, and a locked phone's extensions can't decrypt what a push brought,
/// so while records are held unread the widget retries soon — backing off to
/// hourly after two hours, so a long lock (or a record nobody can ever read,
/// held until the app gives up on it) doesn't spend WidgetKit's daily budget.
enum WidgetReloadPolicy {
    /// All caught up: the refresh is only a backstop for dropped pushes.
    static let settled: TimeInterval = 60 * 60

    static func nextReload(heldSince: Date?, incomplete: Bool, now: Date = Date()) -> Date {
        if let heldSince {
            let waited = now.timeIntervalSince(heldSince)
            let delay: TimeInterval = switch waited {
            // Each tick is spent per widget kind from WidgetKit's daily budget
            // (roughly 40–70), on top of the hourly backstop and every push's reload.
            case ..<(30 * 60): 10 * 60
            case ..<(2 * 60 * 60): 20 * 60
            default: settled
            }
            return now.addingTimeInterval(delay)
        }
        // One batch of a larger delta: the rest is readable, just not fetched yet.
        if incomplete { return now.addingTimeInterval(5 * 60) }
        return now.addingTimeInterval(settled)
    }

    /// Each widget kind runs the provider on its own; one that fetched this
    /// recently already did the round trip for all of them.
    static let sharedFetchWindow: TimeInterval = 60

    static func shouldFetch(lastSyncedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastSyncedAt else { return true }
        return now.timeIntervalSince(lastSyncedAt) >= sharedFetchWindow || lastSyncedAt > now
    }
}
