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
    /// A reload the app or the notification service asked for
    /// (`SharedStore.reloadWidgets`) follows their own refresh or a local-only
    /// change: the store is already current. Shorter than any timer reload, so
    /// WidgetKit deferring that request past it just means a fetch, as before.
    static let siblingReloadWindow: TimeInterval = 2 * 60

    static func shouldFetch(lastSyncedAt: Date?, reloadRequestedAt: Date? = nil, now: Date = Date()) -> Bool {
        if let requested = reloadRequestedAt, requested <= now,
           now.timeIntervalSince(requested) < siblingReloadWindow {
            return false
        }
        guard let lastSyncedAt else { return true }
        return now.timeIntervalSince(lastSyncedAt) >= sharedFetchWindow || lastSyncedAt > now
    }
}

/// One `getTimeline` answer: the entry dates (all rendering the same snapshot)
/// and when WidgetKit should ask again. Nothing else may re-render for a while,
/// so the heart's cooldown and failure notice each get an entry where they end.
struct TimelinePlan: Equatable, Sendable {
    var entries: [Date]
    var nextReload: Date

    init(lastNudgeSentAt: Date?,
         lastNudgeFailedAt: Date?,
         heldSince: Date?,
         incomplete: Bool,
         now: Date = Date()) {
        var entries = [now]
        for expiry in [lastNudgeSentAt?.addingTimeInterval(AppConfig.nudgeCooldown),
                       lastNudgeFailedAt?.addingTimeInterval(AppConfig.nudgeFailureNotice)] {
            if let expiry, expiry > now { entries.append(expiry) }
        }
        self.entries = entries.sorted()
        nextReload = WidgetReloadPolicy.nextReload(heldSince: heldSince, incomplete: incomplete, now: now)
    }
}
