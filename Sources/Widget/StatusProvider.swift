import UIKit
import WidgetKit
import os

struct StatusEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
    /// The photo widget's picture, decoded once for the whole timeline.
    var photo: UIImage?
}

/// Renders from the App Group cache, refreshing from CloudKit as a backstop
/// for pushes that never reached the notification service.
struct StatusProvider: TimelineProvider {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "Widget")

    /// Only the photo widget pays for decoding a picture.
    var drawsPhoto = false
    /// The photo widget's Favourites setting: a starred picture a day.
    var favourites = false

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), content: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // The widget gallery has no data of its own to show, so use the sample.
        guard !context.isPreview else {
            completion(StatusEntry(date: Date(), content: .preview))
            return
        }
        completion(entry(at: Date(), size: context.displaySize))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // WidgetKit calls it once, from whichever thread; it just isn't marked `Sendable`.
        nonisolated(unsafe) let completion = completion
        let size = context.displaySize
        Task { completion(await timeline(size: size)) }
    }

    /// The timeline itself: a refresh if one's due, then the store drawn — and
    /// with Favourites on, tomorrow's picture from midnight.
    func timeline(size: CGSize) async -> Timeline<StatusEntry> {
        let refresh = await Self.refreshIfPossible()
        let snapshot = SharedStore.shared.snapshot
        // The tally, not this refresh's result: a push the NSE couldn't read
        // is still held even when this refresh failed outright.
        let plan = TimelinePlan(lastNudgeSentAt: snapshot.lastNudgeSentAt,
                                lastNudgeFailedAt: snapshot.lastNudgeFailedAt,
                                lastNudgeIssuedAt: snapshot.lastNudgeIssuedAt,
                                heldSince: SharedStore.shared.unreadableTally.heldSince,
                                incomplete: refresh.result?.incomplete ?? false,
                                offline: refresh.offline,
                                locked: refresh.locked || SharedStore.shared.isLockedOut)
        let store = SharedStore.shared
        store.lastWidgetRun = .recorded(after: store.lastWidgetRun, at: Date(), outcome: refresh.outcome,
                                        detail: refresh.detail, nextReload: plan.nextReload)
        let drawn = entry(at: Date(), size: size)
        var entries = plan.entries.map { StatusEntry(date: $0, content: drawn.content, photo: drawn.photo) }
        // Tomorrow's favourite takes over at midnight without a reload.
        if favourites, let midnight = Calendar.current.date(byAdding: .day, value: 1,
                                                            to: Calendar.current.startOfDay(for: Date())) {
            entries.append(entry(at: midnight, size: size))
            entries.sort { $0.date < $1.date }
        }
        return Timeline(entries: entries, policy: .after(plan.nextReload))
    }

    func entry(size: CGSize) -> StatusEntry { entry(at: Date(), size: size) }

    private func entry(at date: Date, size: CGSize) -> StatusEntry {
        var content = WidgetContent(store: SharedStore.shared)
        content.photo = content.picture(favourites: favourites, on: date)
        let photo = drawsPhoto ? content.photo.flatMap { WidgetPhoto.image(for: $0, pointSize: size) } : nil
        return StatusEntry(date: date, content: content, photo: photo)
    }

    /// `offline`: no route or no sign-in, so the next reload backs off (`WidgetReloadPolicy`).
    /// `locked`: the store can't be read before first unlock, so it comes sooner.
    private struct Refresh: Sendable {
        var result: RefreshResult?
        var offline = false
        var locked = false
        var outcome: SharedStore.WidgetRun.Outcome
        var detail: String?
    }

    /// Every kind's provider in this process joins the one refresh in flight.
    private static let refreshFlight = SingleFlight<Refresh>()

    /// Best effort — a failure here just means the cached snapshot is served.
    private static func refreshIfPossible() async -> Refresh {
        switch await MainActor.run(body: { SharedStore.shared.pairingState }) {
        case .paired: break
        case .unpaired: return Refresh(outcome: .unpaired)
        // Not "unpaired": a locked phone's run, retried soon (`WidgetReloadPolicy.whileLocked`).
        case .unreadable: return Refresh(locked: true, outcome: .failed,
                                         detail: String(localized: "data locked until first unlock"))
        }
        let store = SharedStore.shared
        guard WidgetReloadPolicy.shouldFetch(lastSyncedAt: store.snapshot.lastSyncedAt,
                                             reloadRequestedAt: store.widgetReloadRequestedAt) else {
            return Refresh(outcome: .skipped)
        }
        // iCloud asked us to slow down: retrying sooner can extend it.
        guard !store.fetchWaitsOutThrottle() else {
            return Refresh(outcome: .skipped, detail: String(localized: "iCloud asked to wait"))
        }
        return await refreshFlight.run {
            do {
                let started = Date()
                // WidgetKit gives the provider a limited budget; give up well before it.
                let result = try await withDeadline(AppConfig.widgetDeadline) { try await Backend.current.refresh() }
                // Online, and time to spare: a status Siri or the quick-status button
                // couldn't send goes now, not whenever the app next runs (invariant 11).
                if Date().timeIntervalSince(started) < AppConfig.owedRetryExtensionBudget {
                    await QuickStatus.sendOwed()
                }
                // Often the first of ours to run after an unlock: it rewords what a
                // locked phone's pushes couldn't. Bounded, like everything here.
                try? await withDeadline(3) { await BannerUpkeep.run(caughtUp: result.isWholeDelta) }
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
