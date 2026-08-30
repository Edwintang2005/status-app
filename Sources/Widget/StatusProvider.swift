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

    /// WidgetKit gives the provider a limited budget; give up well before it.
    private static let fetchTimeout: Duration = .seconds(8)
    /// Each tick costs a process launch + CloudKit round trip; it's a backstop,
    /// so it can afford to be lazy.
    private static let refreshInterval: TimeInterval = 60 * 60

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
            await Self.refreshIfPossible()
            let snapshot = SharedStore.shared.snapshot
            var entries = [StatusEntry(date: Date(), snapshot: snapshot)]
            // Nothing else re-renders for up to an hour, so schedule the entry
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
            let next = Date().addingTimeInterval(Self.refreshInterval)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    /// Best effort — a failure here just means the cached snapshot is served.
    private static func refreshIfPossible() async {
        guard await MainActor.run(body: { SharedStore.shared.pairing != nil }) else { return }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await Backend.current.refresh() }
                group.addTask {
                    try await Task.sleep(for: fetchTimeout)
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            log.notice("Widget refresh skipped: \(error.localizedDescription)")
        }
    }
}
