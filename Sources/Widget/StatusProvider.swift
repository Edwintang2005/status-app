import WidgetKit
import os

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

/// Renders from the App Group cache, opportunistically refreshing from
/// CloudKit as a backstop for dropped silent pushes.
struct StatusProvider: TimelineProvider {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "Widget")

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // The widget gallery has no data of its own to show, so use the sample.
        let snapshot = context.isPreview ? .preview : SharedStore.shared.snapshot
        completion(StatusEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let result = await Self.refreshIfPossible()
            let snapshot = SharedStore.shared.snapshot
            var entries = [StatusEntry(date: Date(), snapshot: snapshot)]
            // Nothing else may re-render for a while, so schedule the entry
            // that flips the heart back after the cooldown.
            if let sent = snapshot.lastNudgeSentAt {
                let expiry = sent.addingTimeInterval(AppConfig.nudgeCooldown)
                if expiry > Date() {
                    entries.append(StatusEntry(date: expiry, snapshot: snapshot))
                }
            }
            // Same for the failed-nudge slashed heart.
            if let failed = snapshot.lastNudgeFailedAt {
                let expiry = failed.addingTimeInterval(AppConfig.nudgeFailureNotice)
                if expiry > Date() {
                    entries.append(StatusEntry(date: expiry, snapshot: snapshot))
                }
            }
            // The tally, not this refresh's result: a push the NSE couldn't read
            // is still held even when this refresh failed outright.
            let next = WidgetReloadPolicy.nextReload(heldSince: SharedStore.shared.unreadableTally.heldSince,
                                                     incomplete: result?.incomplete ?? false)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    /// Best effort — a failure here just means the cached snapshot is served.
    private static func refreshIfPossible() async -> RefreshResult? {
        guard await MainActor.run(body: { SharedStore.shared.pairing != nil }) else { return nil }
        do {
            // WidgetKit gives the provider a limited budget; give up well before it.
            return try await withDeadline(AppConfig.widgetDeadline) { try await Backend.current.refresh() }
        } catch {
            log.notice("Widget refresh skipped: \(error.localizedDescription)")
            return nil
        }
    }
}
