import Foundation
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// The fields widgets draw (derived from the index), and when they reload (invariant 6).
extension SharedStore {
    /// `true` only inside the WidgetKit extension — deliberately not "any
    /// extension": the notification service still needs to reload widgets.
    static let isRunningInWidgetExtension: Bool = {
        guard let extensionInfo = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any],
              let point = extensionInfo["NSExtensionPointIdentifier"] as? String else {
            return false
        }
        return point == "com.apple.widgetkit-extension"
    }()

    /// Files moments in the history index, refreshes derived snapshot fields,
    /// and trims cached media.
    /// - Returns: whether it reloaded the widgets.
    @discardableResult
    func record(_ moments: [Moment], cleared: (() -> (Moment) -> Bool)? = nil,
                index: MomentIndex = .shared, media: MomentStore = .shared) -> Bool {
        guard !moments.isEmpty else { return false }
        // `nil` for an unreadable index: pruning against just this delta would
        // delete the media of everything else.
        guard let all = index.insertReadable(moments, cleared: cleared) else { return false }
        let redrawn = refreshDerived(index: index).changed

        // Only recent files stay on disk (`MediaRetention`); older media is
        // re-fetched from CloudKit when it's looked at. The drawn picture's are kept.
        let drawn = snapshot.latestPartnerVisualMoment?.id
        media.prune(keeping: MediaRetention.fullCopies(of: all, drawn: drawn),
                    thumbnailsFor: MediaRetention.thumbnails(of: all, drawn: drawn))
        return redrawn
    }

    func record(_ moment: Moment) {
        record([moment])
    }

    /// Recomputes snapshot fields derived from the history index; call whenever
    /// the index changes. The index is read *inside* the locked write: a list
    /// captured earlier can be applied after another process's newer one, and
    /// the widget would regress to an older moment. `alongside` runs in the
    /// same write, so a caller's own change costs no second one.
    /// - Parameter deferringWidgetReload: the gallery's paging — the reload this
    ///   owes is the caller's to make once (`changed`), not one per page.
    /// - Returns: `changed`: whether what the widgets draw moved.
    @discardableResult
    func refreshDerived(deferringWidgetReload: Bool = false,
                        index: MomentIndex = .shared,
                        alongside: ((inout Snapshot) -> Void)? = nil) -> (changed: Bool, snapshot: Snapshot) {
        let (snapshot, redraws) = write { snapshot in
            alongside?(&snapshot)
            // Unreadable isn't empty; the widget keeps what it last showed.
            guard let all = index.loadReadable() else { return }
            Self.fillDerived(&snapshot, from: all)
        }
        if redraws, !deferringWidgetReload { requestWidgetReload() }
        return (redraws, snapshot)
    }

    /// A download wrote these moments' files: the widgets redraw if one is the
    /// picture they show — its file isn't in the snapshot (invariant 6). Every
    /// fetch into the media store ends here, whichever process or path made it.
    func mediaLanded(for ids: [String]) {
        guard let drawn = snapshot.latestPartnerVisualMoment?.id, ids.contains(drawn) else { return }
        requestWidgetReload()
    }

    /// `all` is the whole index, newest first.
    private static func fillDerived(_ snapshot: inout Snapshot, from all: [Moment]) {
        // Unconditional: each field must be able to return to nil when the
        // last moment in its direction is deleted.
        snapshot.latestPartnerMoment = all.first { !$0.fromMe }
        snapshot.latestOwnMoment = all.first { $0.fromMe }
        let picture = WidgetPicture.choose(all.filter { !$0.fromMe && $0.isPicture },
                                           hidden: snapshot.widgetHiddenMomentIDs)
        snapshot.latestPartnerVisualMoment = picture.shown
        snapshot.widgetHiddenMomentIDs = picture.stillHidden
        snapshot.unheardVoiceMemoCount = all
            .filter { !$0.fromMe && $0.isVoice && !$0.seen }
            .count
    }

    /// `widgetNeedsFetch: false` (the usual case) stamps `widgetReloadRequestedAt`:
    /// whoever asked has just applied the delta or changed only local state, so
    /// the widget renders the store without a fetch of its own
    /// (`WidgetReloadPolicy.shouldFetch`). Absorbed while this process holds reloads.
    static func reloadWidgets(widgetNeedsFetch: Bool = false) {
        shared.requestWidgetReload(widgetNeedsFetch: widgetNeedsFetch)
    }

    /// The same, stamping this store — a test's own, never the real container.
    func requestWidgetReload(widgetNeedsFetch: Bool = false) {
        #if canImport(WidgetKit)
        // A reload from inside the widget process would re-enter the timeline
        // provider; WidgetKit already refreshes after interactive intents.
        guard !Self.isRunningInWidgetExtension else { return }
        guard Self.reloadHolds.withLock({ $0 }) == 0 else { return }
        widgetReloadRequestedAt = widgetNeedsFetch ? nil : Date()
        AppConfig.widgetKinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
        #endif
    }

    /// When the app or the notification service last asked for a reload it
    /// didn't need the widget to fetch for; `nil` when the last one did.
    var widgetReloadRequestedAt: Date? {
        get { self[Key.widgetReloadRequestedAt] }
        set { self[Key.widgetReloadRequestedAt] = newValue }
    }

    /// Open holds in this process. While any is open, `reloadWidgets` is
    /// absorbed; each hold's release reloads once.
    fileprivate static let reloadHolds = OSAllocatedUnfairLock(initialState: 0)

    /// Collapses a run's reloads into one — each is a WidgetKit budget spend per
    /// kind. The hold is process-wide; the release's reload stamps this store.
    func holdWidgetReloads() -> WidgetReloadHold {
        Self.reloadHolds.withLock { $0 += 1 }
        return WidgetReloadHold(store: self)
    }

    /// Released at most once — the expiry callback and the task's own exit both try.
    final class WidgetReloadHold: Sendable {
        private let store: SharedStore
        private let open = OSAllocatedUnfairLock(initialState: true)

        fileprivate init(store: SharedStore) {
            self.store = store
        }

        func release(widgetNeedsFetch: Bool) {
            guard open.withLock({ isOpen in defer { isOpen = false }; return isOpen }) else { return }
            SharedStore.reloadHolds.withLock { $0 = max(0, $0 - 1) }
            store.requestWidgetReload(widgetNeedsFetch: widgetNeedsFetch)
        }
    }
}
