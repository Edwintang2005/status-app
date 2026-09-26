import Foundation

/// When the widget next runs its own refresh. Nothing reloads a widget on
/// unlock, and a locked phone's extensions can't decrypt what a push brought,
/// so while records are held unread the widget retries soon — backing off, so a
/// phone locked overnight doesn't spend WidgetKit's daily reload budget.
enum WidgetReloadPolicy {
    /// All caught up: the refresh is only a backstop for dropped pushes.
    static let settled: TimeInterval = 60 * 60

    static func nextReload(heldSince: Date?, incomplete: Bool, now: Date = Date()) -> Date {
        if let heldSince {
            let waited = now.timeIntervalSince(heldSince)
            let delay: TimeInterval = switch waited {
            case ..<(30 * 60): 5 * 60
            case ..<(2 * 60 * 60): 15 * 60
            default: 30 * 60
            }
            return now.addingTimeInterval(delay)
        }
        // One batch of a larger delta: the rest is readable, just not fetched yet.
        if incomplete { return now.addingTimeInterval(5 * 60) }
        return now.addingTimeInterval(settled)
    }
}
