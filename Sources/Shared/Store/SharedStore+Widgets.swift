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
    func record(_ moments: [Moment], cleared: (() -> (Moment) -> Bool)? = nil,
                index: MomentIndex = .shared, media: MomentStore = .shared) {
        guard !moments.isEmpty else { return }
        // `nil` for an unreadable index: pruning against just this delta would
        // delete the media of everything else.
        guard let all = index.insertReadable(moments, cleared: cleared) else { return }
        refreshDerived(reloadWidgets: false, index: index)

        // Only recent files stay on disk (`MediaRetention`); older media is
        // re-fetched from CloudKit when it's looked at.
        let drawn = snapshot.latestPartnerVisualMoment?.id
        media.prune(keeping: MediaRetention.fullCopies(of: all, drawn: drawn),
                    thumbnailsFor: MediaRetention.thumbnails(of: all, drawn: drawn))
        requestWidgetReload()
    }

    func record(_ moment: Moment) {
        record([moment])
    }

    /// Recomputes snapshot fields derived from the history index; call whenever
    /// the index changes. The index is read *inside* the locked mutate: a list
    /// captured earlier can be applied after another process's newer one, and
    /// the widget would regress to an older moment.
    /// Reloads the widgets only when a derived field moved: a moment marked
    /// seen deep in the history changes nothing they draw. `alongside` runs in
    /// the same locked write, so a caller's own change costs no second one.
    @discardableResult
    func refreshDerived(reloadWidgets: Bool = true,
                        index: MomentIndex = .shared,
                        alongside: ((inout Snapshot) -> Void)? = nil) -> (changed: Bool, snapshot: Snapshot) {
        var changed = false
        let snapshot = mutate(reloadWidgets: false) { snapshot in
            alongside?(&snapshot)
            // Unreadable isn't empty; the widget keeps what it last showed.
            guard let all = index.loadReadable() else { return }
            let before = Derived(snapshot)
            Self.fillDerived(&snapshot, from: all)
            changed = Derived(snapshot) != before
        }
        if changed, reloadWidgets { requestWidgetReload() }
        return (changed, snapshot)
    }

    /// What the widgets draw from the fields `fillDerived` owns. Not whole
    /// moments: marking one seen changes no pixel and must not cost a reload.
    struct Derived: Equatable {
        struct Drawn: Equatable {
            var id: String, kind: Moment.Kind, caption: String, senderName: String

            init?(_ moment: Moment?) {
                guard let moment else { return nil }
                (id, kind, caption, senderName) = (moment.id, moment.kind, moment.caption, moment.senderName)
            }
        }
        var partner, own, visual: Drawn?
        var unheard: Int

        init(_ snapshot: Snapshot) {
            partner = Drawn(snapshot.latestPartnerMoment)
            own = Drawn(snapshot.latestOwnMoment)
            visual = Drawn(snapshot.latestPartnerVisualMoment)
            unheard = snapshot.unheardVoiceMemoCount
        }
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
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.momentWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.nudgeWidgetKind)
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
