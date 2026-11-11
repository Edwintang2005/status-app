import UIKit
import WidgetKit
import os

struct StatusEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
    /// The photo widget's picture, decoded once for the whole timeline.
    var photo: UIImage?
}

/// Renders from the App Group cache, opportunistically refreshing from
/// CloudKit as a backstop for dropped silent pushes.
struct StatusProvider: TimelineProvider {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "Widget")

    /// Only the photo widget pays for decoding a picture.
    var drawsPhoto = false

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), content: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // The widget gallery has no data of its own to show, so use the sample.
        guard !context.isPreview else {
            completion(StatusEntry(date: Date(), content: .preview))
            return
        }
        completion(entry(at: Date(), from: SharedStore.shared.snapshot, size: context.displaySize))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // WidgetKit calls it once, from whichever thread; it just isn't marked `Sendable`.
        nonisolated(unsafe) let completion = completion
        let size = context.displaySize
        Task {
            let refresh = await Self.refreshIfPossible()
            let snapshot = SharedStore.shared.snapshot
            // The tally, not this refresh's result: a push the NSE couldn't read
            // is still held even when this refresh failed outright.
            let plan = TimelinePlan(lastNudgeSentAt: snapshot.lastNudgeSentAt,
                                    lastNudgeFailedAt: snapshot.lastNudgeFailedAt,
                                    lastNudgeIssuedAt: snapshot.lastNudgeIssuedAt,
                                    heldSince: SharedStore.shared.unreadableTally.heldSince,
                                    incomplete: refresh.result?.incomplete ?? false,
                                    offline: refresh.offline)
            SharedStore.shared.lastWidgetRun = SharedStore.WidgetRun(at: Date(), outcome: refresh.outcome,
                                                                     detail: refresh.detail,
                                                                     nextReload: plan.nextReload)
            let drawn = entry(at: Date(), from: snapshot, size: size)
            let entries = plan.entries.map { StatusEntry(date: $0, content: drawn.content, photo: drawn.photo) }
            completion(Timeline(entries: entries, policy: .after(plan.nextReload)))
        }
    }

    private func entry(at date: Date, from snapshot: Snapshot, size: CGSize) -> StatusEntry {
        let store = SharedStore.shared
        let content = WidgetContent(snapshot: snapshot,
                                    reportedAt: store.hiddenPartnerStatusAt,
                                    filterEnabled: store.contentFilterEnabled)
        let photo = drawsPhoto ? content.photo.flatMap { WidgetPhoto.image(for: $0, pointSize: size) } : nil
        return StatusEntry(date: date, content: content, photo: photo)
    }

    /// `offline`: no route or no sign-in, so the next reload backs off (`WidgetReloadPolicy`).
    private struct Refresh: Sendable {
        var result: RefreshResult?
        var offline = false
        var outcome: SharedStore.WidgetRun.Outcome
        var detail: String?
    }

    /// Every kind's provider in this process joins the one refresh in flight.
    private static let refreshFlight = SingleFlight<Refresh>()

    /// Best effort — a failure here just means the cached snapshot is served.
    private static func refreshIfPossible() async -> Refresh {
        guard await MainActor.run(body: { SharedStore.shared.pairing != nil }) else { return Refresh(outcome: .unpaired) }
        let store = SharedStore.shared
        guard WidgetReloadPolicy.shouldFetch(lastSyncedAt: store.snapshot.lastSyncedAt,
                                             reloadRequestedAt: store.widgetReloadRequestedAt) else {
            return Refresh(outcome: .skipped)
        }
        return await refreshFlight.run {
            do {
                // WidgetKit gives the provider a limited budget; give up well before it.
                let result = try await withDeadline(AppConfig.widgetDeadline) { try await Backend.current.refresh() }
                // Often the first of ours to run after an unlock: it rewords what a
                // locked phone's pushes couldn't. Bounded, like everything here.
                try? await withDeadline(3) { await BannerUpkeep.run() }
                return Refresh(result: result, outcome: .fetched)
            } catch {
                log.notice("Widget refresh skipped: \(error.localizedDescription)")
                let quiet = WidgetReloadPolicy.waitsQuietly(after: error)
                return Refresh(offline: quiet, outcome: quiet ? .unreachable : .failed,
                               detail: error is CancellationError
                                   ? String(localized: "no answer in time") : error.localizedDescription)
            }
        }
    }
}
