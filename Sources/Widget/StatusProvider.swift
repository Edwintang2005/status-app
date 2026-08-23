import WidgetKit
import os

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

/// Renders from the App Group cache so there is always something to show
/// instantly, and opportunistically refreshes from CloudKit so the widget stays
/// current even if a silent push was dropped or the app hasn't been opened.
struct StatusProvider: TimelineProvider {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "Widget")

    /// WidgetKit gives the provider a limited budget; give up well before it.
    private static let fetchTimeout: Duration = .seconds(8)
    /// The only part of the widget that costs battery: each tick spends a
    /// process launch and a CloudKit round trip. It's a backstop for dropped
    /// silent pushes, not the primary path, so it can afford to be lazy.
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
            let entry = StatusEntry(date: Date(), snapshot: SharedStore.shared.snapshot)
            let next = Date().addingTimeInterval(Self.refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(next)))
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
