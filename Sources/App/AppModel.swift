import CloudKit
import Foundation
import Observation
import SwiftUI
import UserNotifications
import WidgetKit
import os

@MainActor
@Observable
final class AppModel {
    /// The live model, for the app delegate's notification-action handler —
    /// the only caller with no view hierarchy to reach it through.
    @ObservationIgnored static weak var current: AppModel?

    let store: SharedStore
    let log = Logger(subsystem: AppConfig.appGroupID, category: "AppModel")

    private(set) var snapshot: Snapshot
    private(set) var isPaired: Bool
    private(set) var role: PairRole?
    /// Owner side: invite revoked from Settings or Diagnostics.
    var inviteClosed: Bool
    /// The pairing step under way, named so its screen's spinner sits on the
    /// button that started it.
    enum PairingOperation: Equatable { case joining, creatingInvite, unlinking, blocking }
    var pairingOperation: PairingOperation?
    var isBusy: Bool { pairingOperation != nil }

    /// Steps can overlap (Block, then Unlink, from Settings) without nesting: a
    /// step ending clears only its own mark, so none outlives every step.
    func endPairingOperation(_ operation: PairingOperation) {
        if pairingOperation == operation { pairingOperation = nil }
    }
    /// When to fetch and what runs after — launch, foreground, pushes, the
    /// network (`SyncCoordinator`); this model is its host.
    @ObservationIgnored let sync: SyncCoordinator
    var isRefreshing: Bool { sync.isRefreshing }
    /// Syncs keep failing (`SyncCoordinator.failedFetches`); the offline card covers no network.
    /// Not once another process's fetch landed since (a reused foreground fetch, the NSE's push).
    var syncKeepsFailing: Bool {
        guard sync.failedFetches >= AppConfig.fetchFailuresShown, let failed = sync.lastFetchFailedAt else { return false }
        return (snapshot.lastSyncedAt ?? .distantPast) < failed
    }
    /// A sync from nothing under way on a phone that has never synced (a reinstall,
    /// a new pairing) — not a re-sweep of a history already here.
    var isRestoringHistory: Bool {
        isRefreshing && snapshot.lastSyncedAt == nil && store.historyCoverage == HistoryCoverage.owed
    }
    /// No network path — display only (Home's card, the gallery's wording).
    var isOffline: Bool { sync.isOffline }
    /// The path is down because mobile data is off for this app — the one cause the user can fix.
    var mobileDataDenied: Bool { sync.mobileDataDenied }
    /// Non-nil when the backend can't work — no iCloud account, and so on.
    var readinessMessage: String? { sync.readinessMessage }
    /// The recovery pass's media top-up, run beside it: a slow download mustn't hold the sends.
    @ObservationIgnored var mediaTopUp: Task<Void, Never>?
    /// Favourites whose download failed, when: a recovery pass doesn't ask again
    /// for `AppConfig.favouriteRetryInterval` (in memory: each launch tries once).
    @ObservationIgnored var favouriteFetchFailedAt: [String: Date] = [:]
    /// What's holding the screen awake: one owner, so a recap closing can't let
    /// a fresh start's clear or an archive sleep under it.
    enum KeepAwake: Hashable { case freshStartClear, recap, archive }
    @ObservationIgnored var keepAwake: Set<KeepAwake> = [] {
        didSet { UIApplication.shared.isIdleTimerDisabled = !keepAwake.isEmpty }
    }

    func keepAwake(_ reason: KeepAwake, _ on: Bool) {
        if on { keepAwake.insert(reason) } else { keepAwake.remove(reason) }
    }
    /// The offline-send loops, over the same store and backend as this model.
    @ObservationIgnored let outbox: Outbox
    @ObservationIgnored private let backendProvider: () -> any AppBackend
    var backend: any AppBackend { backendProvider() }
    /// The home footer shows "Sending…" while it runs.
    var isRetryingUploads: Bool { outbox.isRetryingUploads }
    /// Any moment upload running, including one still going after its caller stopped waiting.
    var isUploading: Bool { !outbox.uploadsInFlight.isEmpty }
    /// When a send last failed on a full iCloud (`SendFailure.storageFull`).
    var storageFullAt: Date? { outbox.storageFullAt }

    /// Status publishes this model has in flight — not yet "waiting to send".
    private var statusSendsInFlight = 0
    /// The footer's tap-to-retry is running.
    private(set) var isSendingNow = false
    /// Owner side: the link to hand to the partner. Kept after the invite
    /// closes — the same link re-admits the existing partner on a new phone.
    /// Seeded from the store so it survives a relaunch — see `refreshInviteURL()`.
    var inviteURL: URL?
    /// A pairing found on the server with no local state — a fresh install on
    /// a new phone. The pairing screen offers it as "Rejoin".
    var rejoinablePairing: (role: PairRole, zoneID: CKRecordZone.ID)?
    /// The server has no share at all (vs. one that was closed) — keeps Settings from spinning forever.
    var inviteLinkUnavailable = false
    /// Full moment history, newest first, from `MomentIndex` (the snapshot only carries the newest each way).
    private(set) var history: [Moment] = [] {
        didSet {
            owedCaptionIDs = Self.owedCaptions(in: history)
            historyByID = Self.byID(history)
        }
    }
    /// `history` by id: the gallery reads it on every page turn, and 5,000 linear scans add up.
    private(set) var historyByID: [String: Moment] = [:]
    /// Sent moments whose edited caption is still owed: kept with `history`, not
    /// re-scanned on every Home render (`pendingSendCount`).
    @ObservationIgnored private var owedCaptionIDs: Set<String> = []
    @ObservationIgnored private var indexWritesPending = 0
    @ObservationIgnored var shareClaimWake: Task<Void, Never>?
    private static let indexWrites = DispatchQueue(label: "RedString.indexWrites", qos: .userInitiated)

    private static func byID(_ moments: [Moment]) -> [String: Moment] {
        Dictionary(moments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func owedCaptions(in history: [Moment]) -> Set<String> {
        Set(history.lazy.filter { $0.fromMe && $0.uploaded && !$0.captionPublished }.map(\.id))
    }
    /// Your own last few distinct statuses, newest first — the picker's "Recent".
    /// Cached: the picker's sheet content reads it on every Home render.
    private(set) var recentStatuses: [StatusHistoryEntry] = []
    @ObservationIgnored var recentStatusesKey: RecentStatusesKey?

    /// Set when an invite was just created so `RootView` can present it.
    /// Wrapped, not a plain `URL`: `sheet(item:)` needs identity.
    var presentedInvite: InviteLink?

    /// A link to show, wrapped so SwiftUI can key a sheet on it.
    struct InviteLink: Identifiable {
        let id = UUID()
        let url: URL
    }

    var errorMessage: String? {
        didSet { if errorMessage == nil { errorTitle = nil } }
    }
    /// The alert's title for `errorMessage`; set before it. `nil` falls back to a generic one.
    var errorTitle: String?
    var errorAlertTitle: String { errorTitle ?? String(localized: "Something went wrong") }
    /// Informational, not a failure — shown under its own title (see `RootView`).
    var noticeMessage: String?

    /// Where a deep link, a widget or a tapped banner wants Home to go. Latched
    /// until Home can present it — see `HomeView.consumePendingRoute`.
    enum Route: Equatable {
        case compose
        /// A moment banner's "Reply with a photo": the composer, camera open.
        case replyWithPhoto
        /// The new-arrivals carousel, or the newest moment when caught up.
        case newMoments
        case moment(String)
        /// A milestone reminder was tapped: the easter egg, whose tie (kept on
        /// purpose) opens the count that names the milestone.
        case anniversary
        /// The Christmas note was tapped: that year's recap.
        case recap(Int)
    }
    var pendingRoute: Route?

    /// When a send of ours was last confirmed delivered — Home's footer says so briefly.
    private(set) var sendConfirmedAt: Date?

    /// A tapped invite held until `WelcomeView` has a display name — see `acceptInvite(name:)`.
    var pendingInvite: CKShare.Metadata?

    /// Guideline 1.2: nothing else shows until the current terms are agreed to.
    var termsAccepted: Bool
    /// `wordsAt` of a reported partner status — see `SharedStore.hiddenPartnerStatusAt`.
    var hiddenPartnerStatusAt: Date?
    /// Owner side: the "when did you two begin?" prompt is owed — see `SharedStore.anniversaryPromptPending`.
    var anniversaryPromptPending = false
    /// `HomeView` has a sheet up. Root-level presentations (the anniversary
    /// prompt) wait for it to close rather than being dropped by SwiftUI.
    var homeSheetShowing = false
    /// Owner side: people other than the owner on the share, from the last
    /// check (`checkShareMembers`). More than one is the stranger warning.
    var shareMemberCount: Int?
    @ObservationIgnored var shareMembersCheckedAt: Date?
    var closeLinkPromptDismissed: Bool
    var widgetTipDismissed: Bool
    /// The year whose Home recap card was waved away.
    var recapNoticeDismissed: Int?
    /// Diagnostics' "Show the recap card on Home": the twelve-month card, any month.
    var recapCardPreview = false
    /// Home's "notifications are off" card, re-read on every foregrounding.
    var notificationsNotice: NotificationsNotice?
    /// A heart is on its way. The app's nudge has no deadline (its cooldown
    /// release lives in `CloudSync.sendNudge`), so the button holds still meanwhile.
    private(set) var isSendingNudge = false
    /// `wordsAt` of the partner status whose filter-hidden words were revealed
    /// here — until they change it.
    var revealedPartnerWordsAt: Date?
    /// Library tiles' missing thumbnails, batched (`ThumbnailFetcher`).
    @ObservationIgnored private let thumbnailFetcher: ThumbnailFetcher
    /// `createInvite` found this account's old space still has someone in it;
    /// the pairing screen asks before deleting it (`createInvite(replacingExisting:)`).
    var confirmingReplacePairing = false
    /// Home's partner-left notice asked Settings to open on the unlink dialog.
    var unlinkRequested = false
    /// Opt-in milestone reminders on this phone — see `MilestoneReminderPlan`.
    var milestoneRemindersEnabled: Bool {
        didSet {
            guard oldValue != milestoneRemindersEnabled else { return }
            store.milestoneRemindersEnabled = milestoneRemindersEnabled
            if milestoneRemindersEnabled {
                Task { await NotificationManager.requestAuthorizationIfNeeded() }
            }
            syncMilestoneReminders()
        }
    }
    /// How loudly each kind of partner notification arrives on this phone —
    /// applied by the notification service and the app's own posts.
    var notificationPreferences: NotificationPreferences {
        didSet {
            guard oldValue != notificationPreferences else { return }
            store.notificationPreferences = notificationPreferences
        }
    }
    /// What was last handed to the system, so `reload` reschedules only on change.
    @ObservationIgnored private var scheduledReminders: [MilestoneReminderPlan.Reminder]?
    @ObservationIgnored private var reminderSync: Task<Void, Never>?
    /// What `syncRecapReminder` last scheduled; outer `nil` until the first sync.
    @ObservationIgnored var scheduledRecapReminder: RecapPlan.Reminder??
    @ObservationIgnored var recapReminderSync: Task<Void, Never>?
    @ObservationIgnored private var isCleaningSubscriptions = false
    /// The gallery marked moments seen without reloading the widgets each page.
    @ObservationIgnored private var widgetReloadOwed = false

    // State of the extensions in the AppModel+ files (an extension can't hold any).

    /// The on-device word filter over the partner's text; widgets read the same switch.
    var contentFilterEnabled: Bool {
        didSet {
            guard oldValue != contentFilterEnabled else { return }
            store.contentFilterEnabled = contentFilterEnabled
            // A kept recap was drawn under the old setting.
            RecapStore.shared.removeAll()
            SharedStore.reloadWidgets()
        }
    }

    /// The old space the replace dialog would delete has someone on it.
    var replacingSpaceHasPartner = false
    /// The server's view of the link backs Home's close prompt this launch.
    var invitePostureChecked = false
    /// An invite close or reopen is in flight. Its own flag, not `isBusy`: a
    /// photo send finishing would clear that one mid-handshake and admit a second close.
    var isChangingInviteLink = false
    /// Bumped by every close or reopen from here, so a posture check that
    /// started before one can't write its older answer over it.
    @ObservationIgnored var inviteChanges = 0
    /// Settings asks before the re-seat handshake: set when a plain close found
    /// someone on the share (or the partner is known to be in).
    var confirmingInviteReseat = false
    /// Settings' result line after a close or reopen.
    var inviteNotice: String?

    /// `0...1` while an archive is being written, `nil` otherwise.
    var archiveProgress: Double?
    /// Settings' "Clear downloaded media" is deleting: an archive started now
    /// could find a file on this phone and lose it before copying it.
    var isClearingMedia = false
    @ObservationIgnored var archiveTask: Task<MemoryArchive.Outcome?, Never>?
    /// Bumped per archive and by a cancel: a cancelled run winding down in the
    /// background no longer reports progress or offers a share.
    @ObservationIgnored var archiveRun = 0
    /// The last archive that only reached this device — must be offered for sharing before any delete.
    var archiveToShare: URL?

    /// An ask, agree or withdraw is in flight.
    var isChangingFreshStart = false

    /// Only the snapshot store and the backend are injected (`nil` is
    /// `Backend.current`, looked up per call): the moment index, status log,
    /// media store and `SyncRunner` stay process-wide, the real App Group even in a preview.
    init(store: SharedStore = .shared, backend: (any AppBackend)? = nil) {
        self.store = store
        #if DEBUG
        self.sync = SyncCoordinator(ignoresNetwork: DemoMode.isActive)
        #else
        self.sync = SyncCoordinator()
        #endif
        let backendProvider: () -> any AppBackend = backend.map { fixed in { fixed } } ?? { Backend.current }
        self.backendProvider = backendProvider
        self.outbox = Outbox(store: store,
                             index: .shared,
                             statusLog: .shared,
                             backend: { backendProvider() },
                             hasMedia: { MomentStore.shared.hasMedia(for: $0) },
                             uploadSize: { MomentStore.shared.uploadSize(for: $0) },
                             deleteMedia: { MomentStore.shared.delete(id: $0) },
                             clearRecaps: { RecapStore.shared.removeAll() },
                             protect: { name, body in try await AppModel.withUploadProtection(name, body) },
                             indexChanged: { store.refreshDerived() })
        let log = log
        self.thumbnailFetcher = ThumbnailFetcher { moments in
            let backend = backendProvider()
            do {
                try await withDeadline(AppConfig.publishDeadline) { try await backend.fetchThumbnails(for: moments) }
            } catch {
                log.error("Couldn't fetch \(moments.count) thumbnail(s): \(error.localizedDescription)")
            }
            return Set(moments.lazy.map(\.id).filter { MomentStore.shared.hasThumbnail(for: $0) })
        }
        self.snapshot = store.snapshot
        // Now, not after the first fetch: offline that can take minutes, and an
        // empty history greys out the library and hides the moment card.
        let history = MomentIndex.shared.load()
        self.history = history
        self.owedCaptionIDs = Self.owedCaptions(in: history)
        self.historyByID = Self.byID(history)
        self.isPaired = store.pairing != nil
        self.role = store.pairing?.role
        self.inviteClosed = store.inviteClosed
        self.inviteURL = store.inviteURL
        self.contentFilterEnabled = store.contentFilterEnabled
        self.readReceiptsEnabled = store.readReceiptsEnabled
        self.termsAccepted = store.acceptedTermsVersion >= AppConfig.termsVersion
        self.hiddenPartnerStatusAt = store.hiddenPartnerStatusAt
        self.anniversaryPromptPending = store.anniversaryPromptPending
        self.closeLinkPromptDismissed = store.closeLinkPromptDismissed
        self.widgetTipDismissed = store.widgetTipDismissed
        self.recapNoticeDismissed = store.recapNoticeDismissed
        self.partnerLeftNoticeDismissed = store.partnerLeftNoticeDismissed
        self.milestoneRemindersEnabled = store.milestoneRemindersEnabled
        self.notificationPreferences = store.notificationPreferences
        // A retried send confirms like a first one.
        outbox.uploaded = { [weak self] _ in self?.noteUploaded() }
        // Includes a clear that stood aside for the upload.
        outbox.linkFreed = { [weak self] in Task { await self?.sendQueued(automatic: true) } }
        refreshRecentStatusesIfNeeded()
        sync.host = self
    }

    // MARK: - Derived

    /// The partner's name as shown everywhere — filtered like any of their text.
    var partnerName: String { snapshot.partnerName(filterEnabled: contentFilterEnabled) }
    /// `partnerName` for mid-sentence: "your partner" until they've a name.
    var partnerNameInSentence: String { snapshot.partnerNameInSentence(filterEnabled: contentFilterEnabled) }

    /// When the two of them began, as the owner set it — `nil` until they do.
    var anniversary: Anniversary? { snapshot.anniversary }
    /// Only the zone owner sets the date; the participant just receives it.
    var canEditAnniversary: Bool { isPaired && role == .owner }

    /// The partner unlinked from their side; the space is still here.
    var partnerHasLeft: Bool { isPaired && snapshot.partnerHasLeft }
    /// The urgent card, until waved away for this departure; the partner card keeps saying it.
    var showsPartnerLeftNotice: Bool {
        partnerHasLeft && snapshot.partnerLeftAt != partnerLeftNoticeDismissed
    }
    private(set) var partnerLeftNoticeDismissed: Date?

    func dismissPartnerLeftNotice() {
        persist(snapshot.partnerLeftAt, \.partnerLeftNoticeDismissed, \.partnerLeftNoticeDismissed)
    }

    /// Whether this person has ever set a name — the one gate before the rest
    /// of the app, since everything sent carries it and there's no sensible default.
    var hasName: Bool {
        snapshot.mine?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var myDisplayName: String {
        get { snapshot.mine?.displayName ?? "" }
        set { setName(newValue) }
    }

    var nudgeCooldownRemaining: TimeInterval {
        guard let last = snapshot.lastNudgeSentAt else { return 0 }
        return max(0, AppConfig.nudgeCooldown - Date().timeIntervalSince(last))
    }

    var canNudge: Bool { isPaired && nudgeCooldownRemaining == 0 }

    /// Newest photo or doodle *the partner sent* — what the home card shows.
    /// Own sends must not replace it; voice memos get their own row instead.
    var latestVisualMoment: Moment? {
        history.first { !$0.fromMe && $0.isPicture }
    }

    /// Partner's unviewed pictures, newest first — the same order the home card previews.
    var unseenVisualMoments: [Moment] {
        history.filter { !$0.fromMe && !$0.seen && $0.isPicture }
    }

    /// The last memo the partner sent, heard or not — kept playable on the home screen.
    var latestReceivedVoiceMemo: Moment? {
        history.first { !$0.fromMe && $0.isVoice }
    }

    /// Own moments not yet in CloudKit and not uploading right now — the
    /// outbox's retry set. A first upload under way isn't "waiting to send".
    var pendingUploadCount: Int {
        let inFlight = outbox.uploadsInFlight
        return history.count { $0.fromMe && !$0.uploaded && !inFlight.contains($0.id) }
    }

    /// The status on screen hasn't reached iCloud and no publish is under way.
    var myStatusWaitingToSend: Bool {
        isPaired && snapshot.mine != nil && !snapshot.myStatusPublished && statusSendsInFlight == 0
    }

    /// Everything of ours still only on this iPhone — the sync footer's count.
    var pendingSendCount: Int {
        guard isPaired, let role else { return 0 }
        var count = pendingUploadCount + snapshot.unpublishedCount(role: role)
            + owedCaptionIDs.subtracting(outbox.captionsInFlight).count + outbox.owedDeletionCount
        if !snapshot.myStatusPublished, snapshot.mine != nil, statusSendsInFlight > 0 { count -= 1 }
        return count
    }

    /// When the partner saw the status currently in `mine` — the "Seen …" line
    /// under it. `nil` while unseen, for an older status, or with receipts off.
    var myStatusSeenAt: Date? {
        readReceiptsEnabled ? snapshot.myStatusSeenAt : nil
    }

    /// What tapping the home card opens: whatever is unseen, else just the most recent.
    var carouselMoments: [Moment] {
        let unseen = unseenVisualMoments
        if !unseen.isEmpty { return unseen }
        return [latestVisualMoment].compactMap { $0 }
    }

    /// This phone only: nothing drawn on a widget, nothing sent. Shown at once,
    /// written behind (`writeIndex`); a full copy is fetched so it opens offline.
    func setFavourite(_ moment: Moment, _ favourite: Bool) {
        guard let index = history.firstIndex(where: { $0.id == moment.id }) else { return }
        history[index].favouritedAt = favourite ? Date().wholeSeconds : nil
        let id = moment.id
        writeIndex { MomentIndex.shared.setFavourite(id: id, favourite) }
        if favourite { Task { _ = await ensureMedia(for: moment) } }
    }

    /// Looked at, or — for a memo — listened to.
    /// `reloadWidgets: false` while paging the gallery: one reload when it
    /// closes (`flushWidgetReload`), not one per page.
    func markSeen(_ moment: Moment, reloadWidgets: Bool = true) {
        guard !moment.seen, !moment.fromMe else { return }
        if let index = history.firstIndex(where: { $0.id == moment.id }) {
            // One assignment: each one rebuilds `history`'s derived lookups.
            var seen = history[index]
            seen.seen = true
            seen.seenAt = Date().wholeSeconds
            history[index] = seen
        }
        let owesReceipt = readReceiptsEnabled && isPaired
        // Owed now, not when the write lands: the gallery can close first. Only a
        // memo's seen state is drawn (the unheard badge; invariant 6).
        if !reloadWidgets, moment.isVoice { widgetReloadOwed = true }
        let id = moment.id
        let store = store
        writeIndex { [weak self] in
            MomentIndex.shared.markSeen(ids: [id])
            // The widget's unheard-memo badge is a snapshot field; this is what clears it.
            let refreshed = store.refreshDerived(reloadWidgets: reloadWidgets) { snapshot in
                // A write landing after an unlink owes the new pairing nothing.
                if owesReceipt, store.pairing != nil { snapshot.receiptsDirty = true }
                // Seen in the app before any banner said so: none is owed now.
                snapshot.settleOwed([id])
            }
            Task { @MainActor in
                guard let model = self else { return }
                if refreshed.changed, !reloadWidgets { model.widgetReloadOwed = true }
                model.snapshot = refreshed.snapshot
                if owesReceipt { model.outbox.scheduleReceiptFlush() }
            }
        }
    }

    /// The index is rewritten whole (5,000 entries is tens of ms): taps and
    /// page turns write it here, in order, off the main actor. `history` already
    /// shows the change; `reload` leaves it alone until the last write lands.
    private func writeIndex(_ write: @escaping @Sendable () -> Void) {
        indexWritesPending += 1
        Self.indexWrites.async { [weak self] in
            write()
            Task { @MainActor in
                guard let model = self else { return }
                model.indexWritesPending -= 1
                if model.indexWritesPending == 0 { model.update(\.history, MomentIndex.shared.load()) }
            }
        }
    }

    // MARK: - Celebrations

    /// The celebration waiting to be played, if any. Derived from the snapshot,
    /// not latched: every delivery path ends in `reload()`, so nothing extra to set.
    var pendingCelebration: StatusPayload? { snapshot.pendingCelebration }

    /// Called once the animation has been watched. Stamps the status's own
    /// `updatedAt` (not "now") so a re-fetch of the same record can't bring the greeting back.
    func celebrationPlayed() {
        guard let celebration = snapshot.pendingCelebration else { return }
        store.mutate { $0.lastCelebratedAt = celebration.updatedAt }
        reload()
        // A surprise just opened: its words count as read from here.
        markPartnerStatusSeen()
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        sync.startMonitoring()
        // Cold-start link taps land here: the scene delegate ran before any view could listen.
        if let invite = InviteInbox.shared.take() {
            receiveInvite(invite)
        }
        // A receipt write the last run couldn't confirm is re-sent, receipts off
        // too, so a retraction a stale write overtook is healed. Before any
        // await: the scene's own refresh may run its recovery pass first.
        if isPaired { store.mutate(reloadWidgets: false) { $0.rearmUnsettledReceipts() } }
        // An index filled under a smaller cap is swept once to the new one. Every
        // fetch until it ends is a resync: news only what the server created
        // since the last complete fetch (`Snapshot.newsAfter`), older history filed seen.
        if HistoryCoverage.needsSweep(store.historyCoverage) { store.clearChangeTokens() }
        guard isPaired else {
            await sync.checkReadiness()
            return
        }
        // Easy to lose across reinstalls, but re-asserted daily rather than on
        // every launch, and never ahead of the fetch.
        if Date().timeIntervalSince(store.subscriptionsVerifiedAt ?? .distantPast) >= AppConfig.subscriptionCheckInterval {
            Task {
                do {
                    try await bounded { try await $0.registerSubscription() }
                    store.subscriptionsVerifiedAt = Date()
                } catch {
                    self.log.error("Subscription check failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // The scene turning active fetches too: one fetch between them, and
        // the recovery pass (the receipts above) either way.
        await sync.launch()
    }

    /// `.pairingDidChange`: the store moved outside this model's calls (a
    /// background refresh that found the link ended). Re-read, then fetch.
    func reloadFromStore() async {
        reload()
        // A pairing may have just appeared — the first moment the prompt makes sense.
        await NotificationManager.requestAuthorizationIfNeeded()
        await refresh()
    }

    /// Re-reads the store. Each mirror is assigned only when it moved: every
    /// assignment invalidates whatever Home view reads it, and this runs after nearly everything.
    func reload() {
        let pairing = store.pairing
        update(\.snapshot, store.snapshot)
        update(\.isPaired, pairing != nil)
        update(\.role, pairing?.role)
        update(\.inviteClosed, store.inviteClosed)
        // The closed link is kept on purpose — see `refreshInviteURL`.
        update(\.inviteURL, store.inviteURL)
        update(\.hiddenPartnerStatusAt, store.hiddenPartnerStatusAt)
        update(\.anniversaryPromptPending, store.anniversaryPromptPending)
        update(\.closeLinkPromptDismissed, store.closeLinkPromptDismissed)
        if !isPaired {
            update(\.shareMemberCount, nil)
            shareMembersCheckedAt = nil
            update(\.invitePostureChecked, false)
        }
        // A write still queued would be undone here; its landing re-reads instead.
        if indexWritesPending == 0 { update(\.history, MomentIndex.shared.load()) }
        refreshRecentStatusesIfNeeded()
        syncMilestoneReminders()
        syncRecapReminder()
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Writes a store field and this model's mirror of it together.
    func persist<Value>(_ value: Value,
                        _ mirror: ReferenceWritableKeyPath<AppModel, Value>,
                        _ stored: ReferenceWritableKeyPath<SharedStore, Value>) {
        store[keyPath: stored] = value
        self[keyPath: mirror] = value
    }

    /// A backend call under a deadline: CloudKit's own timeout is a week (invariant 22).
    func bounded<T: Sendable>(_ seconds: TimeInterval = AppConfig.publishDeadline,
                              _ call: @escaping @Sendable (any AppBackend) async throws -> T) async throws -> T {
        let backend = backend
        return try await withDeadline(seconds) { try await call(backend) }
    }

    // MARK: - Media on demand

    /// Older entries keep metadata but not media files; fetches the file back from CloudKit on demand.
    func ensureMedia(for moment: Moment) async -> Bool {
        if MomentStore.shared.hasMedia(for: moment) { return true }
        #if DEBUG
        if MomentIndex.isPadding(moment.id) { return false }
        #endif
        // A kind from a newer build: nothing this build could store or draw.
        guard moment.kind.isSupported else { return false }
        do {
            // Bounded: CloudKit's own timeout is a week, and the recovery pass's top-up awaits this.
            try await bounded(AppConfig.archiveItemDeadline) { try await $0.fetchMedia(for: moment) }
            return MomentStore.shared.hasMedia(for: moment)
        } catch {
            log.error("Couldn't fetch media for \(moment.id): \(error.localizedDescription)")
            return false
        }
    }

    #if DEBUG
    /// Diagnostics: fill the index toward its cap with local placeholders (`MomentIndex.padding`).
    func padHistory() {
        let room = AppConfig.momentHistoryLimit - history.count
        let padding = MomentIndex.padding(count: room, before: history.last?.sentAt)
        let store = store
        writeIndex {
            MomentIndex.shared.insert(padding)
            store.refreshDerived()
        }
    }

    func removePadding() {
        let ids = Set(history.lazy.map(\.id).filter(MomentIndex.isPadding))
        let store = store
        writeIndex {
            MomentIndex.shared.remove(ids: ids)
            store.refreshDerived()
        }
    }
    #endif

    /// A favourite starred offline, or whose copy was fetched and lost: its full
    /// copy, a few per pass, so it opens offline as promised.
    func fetchMissingFavourites(now: Date = Date()) async {
        let missing = history.filter { moment in
            guard moment.isFavourite, moment.kind.isSupported, !MomentStore.shared.hasMedia(for: moment) else { return false }
            guard let failed = favouriteFetchFailedAt[moment.id] else { return true }
            return now.timeIntervalSince(failed) >= AppConfig.favouriteRetryInterval
        }
        for moment in missing.prefix(5) {
            guard await ensureMedia(for: moment) else {
                // Offline isn't the favourite's fault: the next pass back online tries it.
                if !isOffline { favouriteFetchFailedAt[moment.id] = now }
                return
            }
            favouriteFetchFailedAt[moment.id] = nil
        }
    }

    /// The home card and photo widget only ever read the thumbnail; the one
    /// download attempt inside a refresh can fail (a widget deadline, a killed
    /// extension), and nothing else would fetch it again.
    func restoreLatestThumbnailIfMissing() async {
        guard let latest = store.snapshot.latestPartnerVisualMoment,
              !MomentStore.shared.hasThumbnail(for: latest.id) else { return }
        if await ensureThumbnail(for: latest) {
            SharedStore.reloadWidgets()
            reload()
        }
    }

    /// The photo widget's picture, or one this phone took off it: the moments
    /// whose "Hide from widget" / "Show in widget" means something.
    func widgetPictureState(of moment: Moment) -> (shown: Bool, hidden: Bool) {
        (snapshot.latestPartnerVisualMoment?.id == moment.id, snapshot.widgetHiddenMomentIDs.contains(moment.id))
    }

    /// This phone only, until a newer picture arrives (`WidgetPicture`); the
    /// widget falls back to the one before, fetched in full for it.
    func setShownInWidget(_ moment: Moment, _ shown: Bool) async {
        let refreshed = store.refreshDerived { snapshot in
            snapshot.widgetHiddenMomentIDs.removeAll { $0 == moment.id }
            if !shown { snapshot.widgetHiddenMomentIDs.append(moment.id) }
        }
        snapshot = refreshed.snapshot
        guard let next = refreshed.snapshot.latestPartnerVisualMoment,
              !MomentStore.shared.hasMedia(for: next) else { return }
        if await ensureMedia(for: next) { SharedStore.reloadWidgets() }
    }

    /// The library grid's version of `ensureMedia`: just the thumbnail, fetched
    /// as the tile scrolls into view, batched with its neighbours. Bounded per
    /// batch: the recovery pass awaits this. `false` when it still isn't on disk.
    func ensureThumbnail(for moment: Moment) async -> Bool {
        if MomentStore.shared.hasThumbnail(for: moment.id) { return true }
        guard !moment.isVoice else { return false }
        #if DEBUG
        // Placeholders have no record to fetch from.
        if MomentIndex.isPadding(moment.id) { return false }
        #endif
        return await thumbnailFetcher.thumbnail(for: moment)
    }

    // MARK: - Status

    /// Whole seconds (invariant 14), and after the status it replaces: two in one
    /// second shared a stamp, so the publish flag could settle on the wrong one.
    private func statusTimestamp() -> Date {
        StatusPayload.nextStamp(after: store.snapshot.mine?.updatedAt)
    }

    /// - Returns: why it didn't reach iCloud now (it's kept and sent later), or `nil` when it did.
    @discardableResult
    func setStatus(emoji: String, message: String, celebration: CelebrationStyle? = nil) async -> SendFailure? {
        let payload = StatusPayload(
            emoji: emoji,
            // Capped here too: the banner reply bypasses the composer's field.
            message: String(message.trimmingCharacters(in: .whitespacesAndNewlines)
                                .prefix(AppConfig.statusMessageMaxLength)),
            displayName: snapshot.mine?.displayName ?? "",
            updatedAt: statusTimestamp(),
            nudgeCount: snapshot.mine?.nudgeCount ?? 0,
            lastNudgeAt: snapshot.mine?.lastNudgeAt,
            isCelebration: celebration != nil,
            celebrationStyle: celebration
        )

        // Show it immediately; marked unpublished in the same mutate so a crash
        // between the two writes can't strand a status that looks delivered.
        // The nudge fields are the store's: the lock-screen heart may have
        // written them since this model last read it.
        let paired = isPaired
        store.mutate {
            var current = payload
            current.nudgeCount = $0.mine?.nudgeCount ?? payload.nudgeCount
            current.lastNudgeAt = $0.mine?.lastNudgeAt ?? payload.lastNudgeAt
            $0.mine = current
            $0.myStatusPublished = !paired
        }
        StatusHistoryLog.shared.record(payload, fromMe: true)
        reload()

        guard paired else { return nil }
        statusSendsInFlight += 1
        defer { statusSendsInFlight -= 1 }
        do {
            // The backend marks it published, against the then-current status (invariant 16).
            // Protected like every send: picked, then the phone locked mid-save.
            try await Self.withUploadProtection("status") {
                try await bounded { try await $0.publish(payload) }
            }
            outbox.noteSendSucceeded()
            reload()
            AccessibilityNotification.Announcement(String(localized: "Status sent to \(partnerName)")).post()
            return nil
        } catch {
            presentSendFailure(error, noun: String(localized: "status update"))
            reload()
            AccessibilityNotification.Announcement(String(localized: "Status saved. It sends once iCloud can be reached.")).post()
            return SendFailure(error)
        }
    }

    /// The welcome screen's name, a rename, or the name typed when joining.
    /// Published at once when paired; before pairing it waits for the zone.
    func setName(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = statusTimestamp()
        let paired = isPaired
        // Built from the store's copy inside the lock: the model's may predate a
        // heart sent from the lock screen, or a status another device set.
        let updated = store.mutate {
            var renamed = $0.mine ?? .initial(displayName: trimmed)
            renamed.displayName = trimmed
            // The words keep their own date; only the record's stamp moves.
            renamed.wordsSince = renamed.wordsAt
            // Fresh stamp: the resync revert-guard orders by `updatedAt`, and a stale one would lose.
            renamed.updatedAt = stamp
            // A local edit, not the server's copy: nothing to order it by yet.
            renamed.serverSavedAt = nil
            $0.mine = renamed
            $0.myStatusPublished = !paired
        }
        let payload = updated.mine ?? .initial(displayName: trimmed)
        reload()

        guard paired else { return }
        // Not logged: the status didn't change, only the name on it — unless the
        // status itself never made it into the log (set offline, then renamed).
        let logged = updated.myStatusLoggedAt != payload.wordsAt
        statusSendsInFlight += 1
        Task { [payload] in
            defer { statusSendsInFlight -= 1 }
            do {
                try await Self.withUploadProtection("rename") {
                    try await bounded { try await $0.publish(payload, logged: logged) }
                }
                outbox.noteSendSucceeded()
                reload()
            } catch {
                // Quiet: the name is right locally, and the outbox's republish carries it over.
                outbox.noteSendFailed(error)
                log.error("Name publish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Nudge

    /// Never queued: a heart is a moment-in-time gesture.
    /// - Returns: `false` only when it was tried and didn't send (a banner's
    /// "Send a heart back" says so); held by the cooldown or already sending is `nil`.
    @discardableResult
    func sendNudge() async -> Bool? {
        // Claimed before the await: the store's cooldown reaches this model only once the call returns.
        guard canNudge, !isSendingNudge else { return nil }
        isSendingNudge = true
        defer { isSendingNudge = false }
        do {
            let sent = try await backend.sendNudge()
            if sent {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AccessibilityNotification.Announcement(String(localized: "Heart sent")).post()
            }
            reload()
            return sent ? true : nil
        } catch {
            // `CloudSync.sendNudge` stamped `lastNudgeFailedAt`: the heart itself
            // says it didn't send, like the lock-screen one.
            log.error("Nudge failed: \(error.localizedDescription, privacy: .public)")
            AccessibilityNotification.Announcement(String(localized: "Heart didn't send")).post()
            reload()
            return false
        }
    }

    // MARK: - Moments

    /// Own moments, within `momentDeleteWindow` of sending or still unsent: gone
    /// from this phone at once, and from iCloud now or once there's a connection.
    func deleteMoment(_ moment: Moment) async {
        guard outbox.deleteMoment(moment) else {
            // The confirmation sat open past the window.
            errorTitle = String(localized: "Too late to delete")
            errorMessage = String(localized: "A moment can be deleted for both of you only within five minutes of sending it.")
            return
        }
        reload()
        guard isPaired else { return }
        await Self.withUploadProtection("delete") { _ = await outbox.sendDeletions() }
        reload()
    }

    /// Own moments only. Filed at once; sent now, or by the recovery pass once
    /// there's a connection. An emptied caption removes it.
    func editCaption(of moment: Moment, to caption: String) async {
        let words = Moment.caption(from: caption)
        guard moment.fromMe, words != moment.caption, outbox.editCaption(of: moment.id, to: words) else { return }
        reload()
        guard isPaired else { return }
        await Self.withUploadProtection("caption") { _ = await outbox.republishCaptions() }
        reload()
    }

    /// Filed locally first so the UI and widget update at once, then uploaded.
    /// A failed upload leaves the local copy in place.
    func sendMoment(image: UIImage, kind: Moment.Kind, caption: String, location: PhotoLocation? = nil) async {
        let moment = newMoment(kind: kind, caption: caption)
        let id = moment.id
        await send(moment, taskName: "moment-upload",
                   saveFailure: String(localized: "Couldn't save that moment")) {
            try MomentStore.shared.write(image, id: id, location: location)
        }
    }

    /// `fileURL` is **moved**, not copied — the caller must not use it afterwards.
    func sendVoiceMemo(fileURL: URL,
                       duration: TimeInterval,
                       waveform: [Double],
                       caption: String) async {
        let moment = newMoment(kind: .voice, caption: caption, duration: duration, waveform: waveform)
        let id = moment.id
        await send(moment, taskName: "voice-memo-upload",
                   saveFailure: String(localized: "Couldn't save that voice memo")) {
            try MomentStore.shared.adoptAudio(from: fileURL, id: id)
        }
    }

    /// `senderName` is captured at send time: older moments keep the name you had then.
    private func newMoment(kind: Moment.Kind,
                           caption: String,
                           duration: TimeInterval = 0,
                           waveform: [Double] = []) -> Moment {
        Moment(kind: kind,
               caption: Moment.caption(from: caption),
               senderName: snapshot.mine?.displayName ?? "",
               fromMe: true,
               duration: duration,
               waveform: waveform)
    }

    /// Media on disk, then the index entry, both before any network call. The
    /// save runs off the main actor: a camera shot's resize and two JPEG encodes hitched Send.
    private func send(_ moment: Moment,
                      taskName: String,
                      saveFailure: String,
                      saveMedia: @escaping @Sendable () throws -> Void) async {
        do {
            try await Self.withUploadProtection("moment-save") {
                try await Task.detached(priority: .userInitiated, operation: saveMedia).value
            }
        } catch {
            present(error, title: saveFailure)
            return
        }

        // Pending only when paired — an unpaired send has nothing to retry.
        var moment = moment
        moment.uploaded = !isPaired
        // Off the main actor, as the composer closes: an index rewrite, a snapshot
        // write and a media prune (all thread-safe) hitched the dismissal.
        let filed = moment
        let store = store
        let paired = isPaired
        // Claimed before it's filed: a retry pass running in the gap would take it,
        // and this send's failure alert would never show.
        if paired { outbox.reserveUpload(moment.id) }
        await Task.detached(priority: .userInitiated) { store.record(filed) }.value
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard paired else { return }
        do {
            try await outbox.upload(moment, taskName: taskName, reserved: true)
        } catch {
            presentSendFailure(error, noun: moment.noun)
        }
    }

    /// Keeps the process running through an upload so a lock can't suspend it
    /// mid-send. Post-await bookkeeping belongs inside `body` (invariant 19).
    static func withUploadProtection<T>(_ name: String,
                                        _ body: () async throws -> T) async rethrows -> T {
        let assertion = BackgroundAssertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            assertion.end()
        }
        defer { assertion.end() }
        return try await body()
    }

    /// Diagnostics: fetches the whole zone again and re-queues own moments it
    /// turns out never to have held (`MomentIndex.requeueMissingUploads`), then
    /// sends them. Returns how many were found missing, or `nil` when the
    /// fetch itself failed — "nothing missing" must never be a guess.
    func resyncHistory() async -> Int? {
        guard isPaired else { return nil }
        // Its own fetch, only if none is running; one asked for meanwhile runs after it.
        let fetched = await sync.exclusiveFetch { [weak self] in
            guard let self else { return false }
            self.store.clearChangeTokens()
            do {
                let pass = try await SyncRunner(store: self.store, backend: { [backendProvider] in backendProvider() },
                                                notifier: AppNotifier()).refreshResult(announce: false)
                // The zone didn't come back whole in one go (its budget, a fresh start held):
                // nothing was checked, so nothing can be said to be missing.
                guard pass.result.checkedWholeZone else {
                    self.log.notice("History resync didn't cover the whole zone in one go.")
                    return false
                }
                return true
            } catch {
                self.log.error("History resync failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        recentStatusesKey = nil
        reload()
        guard fetched == true else { return nil }
        let found = pendingUploadCount
        // After the fetch: sending isn't fetching, and refreshes needn't wait on it.
        await outbox.retryPendingUploads(automatic: false)
        reload()
        return found
    }

    /// A send of ours is confirmed on the server (the outbox marked it).
    private func noteUploaded() {
        history = MomentIndex.shared.load()
        sendConfirmedAt = Date()
    }

    // MARK: - Anniversary

    /// Owner only. Written locally and marked unpublished in one mutate, then
    /// pushed by the outbox's republish — quietly: a failure goes with the next
    /// refresh. `nil` removes the date on both phones.
    func setAnniversary(_ anniversary: Anniversary?) async {
        guard canEditAnniversary else { return }
        store.mutate(reloadWidgets: false) {
            $0.anniversary = anniversary
            $0.anniversaryPublished = false
            // Setting a date answers any standing ask, so it can't resurface
            // if the date is later removed.
            if let asked = $0.anniversaryRequestedAt { $0.anniversaryRequestDismissedAt = asked }
        }
        store.anniversaryPromptPending = false
        reload()
        if await outbox.republishAnniversary() { reload() }
    }

    /// The prompt after creating the link was skipped; Settings still has the row.
    func dismissAnniversaryPrompt() {
        persist(false, \.anniversaryPromptPending, \.anniversaryPromptPending)
    }

    // MARK: - Anniversary request (participant asks, owner answers)

    /// Participant only, and only while there's no date to show.
    var canRequestAnniversary: Bool { isPaired && role == .participant && anniversary == nil }

    /// Participant side: when this device last asked, for the "Asked …" line.
    var anniversaryRequestedAt: Date? {
        role == .participant ? snapshot.anniversaryRequestedAt : nil
    }

    /// Owner side: the partner has asked and this device hasn't answered or dismissed it.
    var anniversaryRequestPending: Bool {
        canEditAnniversary && snapshot.anniversaryRequestPending
    }

    /// Same shape as `setAnniversary`.
    func requestAnniversary() async {
        guard canRequestAnniversary else { return }
        let now = Date().wholeSeconds
        store.mutate(reloadWidgets: false) {
            $0.anniversaryRequestedAt = now
            $0.anniversaryRequestPublished = false
        }
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if await outbox.republishAnniversaryRequest() { reload() }
    }

    /// Owner side: the prompt was waved away; it stays away until they ask again.
    func dismissAnniversaryRequest() {
        store.mutate(reloadWidgets: false) {
            $0.anniversaryRequestDismissedAt = $0.anniversaryRequestedAt
        }
        reload()
    }

    // MARK: - Pending uploads

    /// The home footer's tap-to-retry: what the next refresh would send, without
    /// waiting for one. Says so when it didn't all go — silence read as a dead button.
    func retryPendingNow() async {
        guard !isSendingNow else { return }
        isSendingNow = true
        defer { isSendingNow = false }
        await sendQueued(automatic: false)
        // A full iCloud already names itself in the footer; an upload still
        // running ("Sending…") isn't "not sent".
        if pendingSendCount > 0, storageFullAt == nil, !isUploading {
            errorTitle = String(localized: "Not sent yet")
            errorMessage = String(localized: "Couldn't reach iCloud just now. Everything is saved on this iPhone and will send on the next sync.")
        }
    }

    // MARK: - Read receipts

    /// Whether this device shares (and shows) read receipts. On by default;
    /// each side controls its own sending, and display is gated on the same switch.
    var readReceiptsEnabled: Bool {
        didSet {
            guard oldValue != readReceiptsEnabled else { return }
            store.readReceiptsEnabled = readReceiptsEnabled
            // Publish the backlog when enabling; retract with an empty map when disabling.
            store.mutate(reloadWidgets: false) { $0.receiptsDirty = true }
            Task { await outbox.flushReceipts() }
        }
    }

    /// Records that the partner's current status has been on screen — the
    /// status read receipt. Driven by the home screen, and only while the app
    /// is actually in front with nothing covering it: a background refresh, or
    /// a status landing under the picker, isn't anyone looking.
    func markPartnerStatusSeen() {
        guard isPaired, readReceiptsEnabled, !homeSheetShowing, !rootSheetShowing,
              UIApplication.shared.applicationState == .active else { return }
        // The status this screen shows, not whatever the store has since taken in.
        let shown = snapshot.theirs
        // Reported, or filter-hidden and not revealed: nobody read these words.
        if let shown, !shown.wordsShown(reportedAt: hiddenPartnerStatusAt,
                                        revealed: partnerStatusRevealed,
                                        sealed: snapshot.partnerStatusSealed,
                                        filterEnabled: contentFilterEnabled) { return }
        var changed = false
        let updated = store.mutate(reloadWidgets: false) { changed = $0.stampPartnerStatusSeen(shown, at: Date()) }
        guard changed else { return }
        snapshot = updated
        outbox.scheduleReceiptFlush()
    }

    /// Going to the background: what the debounce was holding goes now,
    /// inside a background task so suspension can't cut it off.
    func flushReceiptsForBackground() async {
        guard isPaired else { return }
        // A page seen just before leaving is still being written: it goes too.
        await withCheckedContinuation { done in Self.indexWrites.async { done.resume() } }
        let outbox = outbox
        await Self.withUploadProtection("receipts") { await outbox.flushReceiptsNow() }
    }

    // MARK: - Status history

    static let recentStatusLimit = 8

    /// Own entries only move with `mine`, a fresh start's clear or the pairing;
    /// a fetch clears the key too (a rejoin files our old logs from the zone).
    private func refreshRecentStatusesIfNeeded() {
        let key = RecentStatusesKey(paired: isPaired,
                                    wordsAt: snapshot.mine?.wordsAt,
                                    emoji: snapshot.mine?.emoji,
                                    message: snapshot.mine?.message,
                                    clearedBefore: snapshot.freshStart.clearedBefore)
        guard key != recentStatusesKey else { return }
        recentStatusesKey = key
        update(\.recentStatuses, StatusHistoryEntry.recentOwn(in: StatusHistoryLog.shared.load(),
                                                               limit: Self.recentStatusLimit))
    }

    struct RecentStatusesKey: Equatable {
        var paired: Bool
        var wordsAt: Date?
        var emoji: String?
        var message: String?
        var clearedBefore: Date?
    }

    // MARK: - Errors

    /// A failed send is filed locally and retried, and Home shows it waiting
    /// (the status row, the footer): no alert. A full iCloud is the exception —
    /// only someone can fix it — once per automatic-retry back-off.
    private func presentSendFailure(_ error: Error, noun: String) {
        log.error("Send failed: \(Self.codePrefix(error), privacy: .public)\(error.localizedDescription, privacy: .public)")
        let alreadyFull = outbox.storageFullAt
        guard outbox.noteSendFailed(error) == .storageFull else { return }
        if let alreadyFull, Date().timeIntervalSince(alreadyFull) < AppConfig.storageFullRetryInterval { return }
        // Whose storage it is decides who can fix it: the zone lives in the owner's iCloud.
        errorTitle = String(localized: "iCloud is full")
        errorMessage = role == .participant
            ? String(localized: "\(partnerName)'s iCloud storage is full. Your shared space lives in their iCloud, so that \(noun) can't be sent until they free up some space. It's saved on this iPhone and will go then.")
            : String(localized: "Your iCloud storage is full, so that \(noun) can't be sent yet. It's saved on this iPhone and will go once there's space. Your shared space lives in your iCloud, so everything either of you sends counts against it.")
    }

    func present(_ error: Error, title: String? = nil) {
        log.error("\(Self.codePrefix(error), privacy: .public)\(error.localizedDescription, privacy: .public)")
        errorTitle = title
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The CKError code for the log — the message alone doesn't tell transient from real.
    private static func codePrefix(_ error: Error) -> String {
        (error as? CKError).map { "CKError \($0.code.rawValue): " } ?? ""
    }
}

// MARK: - Upkeep

/// Housekeeping that follows the model's state: milestone reminders, the
/// unpaired subscription cleanup, the gallery's deferred widget reload.
extension AppModel {
    /// Reschedules only when the plan moved — the date changed, reminders were
    /// toggled, the pair unlinked — since `reload` runs after nearly everything.
    func syncMilestoneReminders() {
        let plan = MilestoneReminderPlan.reminders(for: snapshot.anniversary,
                                                   enabled: milestoneRemindersEnabled,
                                                   paired: isPaired)
        guard plan != scheduledReminders else { return }
        scheduledReminders = plan
        // Chained: a remove-then-add overlapping another could leave stale ones behind.
        let previous = reminderSync
        reminderSync = Task {
            await previous?.value
            await NotificationManager.scheduleMilestoneReminders(plan)
        }
    }

    /// While unpaired, retries removing the old pairing's subscriptions until
    /// both databases confirm (`SharedStore.subscriptionCleanup`). Bounded per
    /// try; a different iCloud account keeps it pending for when they're back.
    func cleanUpSubscriptionsIfNeeded() async {
        #if DEBUG
        if DemoMode.isActive { return }
        #endif
        guard !isPaired, !isCleaningSubscriptions, let pending = store.subscriptionCleanup else { return }
        isCleaningSubscriptions = true
        defer { isCleaningSubscriptions = false }
        do {
            try await bounded { try await $0.deleteAllSubscriptions(ownedBy: pending.userRecordName) }
        } catch {
            log.notice("Subscription cleanup still pending: \(error.localizedDescription)")
            // A partial delete may have taken a new pairing's subscriptions with it.
            await reregisterIfPairedMeanwhile()
            return
        }
        if store.subscriptionCleanup == pending { store.subscriptionCleanup = nil }
        await reregisterIfPairedMeanwhile()
    }

    /// Paired again while a cleanup's delete was in flight: the subscription IDs
    /// are fixed, so the new pairing's may be gone too — put them back.
    private func reregisterIfPairedMeanwhile() async {
        guard store.pairing != nil else { return }
        try? await bounded { try await $0.registerSubscription() }
    }

    /// The gallery closed: the one reload its pages deferred.
    func flushWidgetReload() {
        guard widgetReloadOwed else { return }
        widgetReloadOwed = false
        SharedStore.reloadWidgets()
    }
}

/// Holds a `UIBackgroundTaskIdentifier` so the expiration handler and the normal
/// completion path can both end it exactly once (a class so both reach the same id).
@MainActor
private final class BackgroundAssertion {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

#if DEBUG
extension AppModel {
    /// A model backed by an isolated defaults suite, for previews.
    static func previewModel(paired: Bool = true) -> AppModel {
        let suite = UserDefaults(suiteName: "redstring.preview.\(UUID().uuidString)")!
        let store = SharedStore(defaults: suite)
        if paired {
            store.pairing = PairingInfo(role: .owner,
                                        zoneName: AppConfig.coupleZoneName,
                                        zoneOwnerName: "__defaultOwner__",
                                        pairedAt: Date())
            store.snapshot = .preview
        }
        return AppModel(store: store)
    }
}
#endif
