import CloudKit
import Foundation
import Network
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
    var isBusy = false
    /// The fetch only (`RefreshGate`): a request mid-fetch runs it once more.
    var refreshGate = RefreshGate()
    var isRefreshing: Bool { refreshGate.isRunning }
    /// The post-fetch recovery pass (republishes, retries, receipts) — outside
    /// `isRefreshing`, so a stalled send can't hold off the next fetch.
    @ObservationIgnored var recoveryGate = RefreshGate()
    /// The offline-send loops, over the same store and backend as this model.
    @ObservationIgnored let outbox: Outbox
    @ObservationIgnored private let backendProvider: () -> any SyncBackend
    var backend: any SyncBackend { backendProvider() }
    /// The home footer shows "Sending…" while it runs.
    var isRetryingUploads: Bool { outbox.isRetryingUploads }
    /// When a send last failed on a full iCloud (`SendFailure.storageFull`).
    var storageFullAt: Date? { outbox.storageFullAt }

    /// Fires a refresh on the offline→online edge — the only trigger that watches the network itself.
    @ObservationIgnored let pathMonitor = NWPathMonitor()
    /// Starts `true` so the monitor's immediate first callback doesn't double up with `onLaunch`'s refresh.
    @ObservationIgnored var networkWasSatisfied = true
    /// No network path — display only (Home's card, the gallery's wording). Sends
    /// never gate on it: it goes stale while suspended, and a banner action wakes
    /// the app before the monitor catches up. They try, and fail quietly offline.
    var isOffline = false
    /// The path is down because mobile data is off for this app — the one cause the user can fix.
    var mobileDataDenied = false
    @ObservationIgnored var offlineShowTask: Task<Void, Never>?
    @ObservationIgnored var catchUpTask: Task<Void, Never>?
    /// Whichever refresh last fetched — the reconnect catch-up judges by it, not by who ran it.
    @ObservationIgnored var lastFetchSucceededAt: Date?
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
    /// Non-nil when the backend can't work — no iCloud account, and so on.
    var readinessMessage: String?
    /// Full moment history, newest first, from `MomentIndex` (the snapshot only carries the newest each way).
    private(set) var history: [Moment] = []
    /// `recentOwnStatuses()`, cached: the picker's sheet content reads it on every Home render.
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
        /// The new-arrivals carousel, or the newest moment when caught up.
        case newMoments
        case moment(String)
        /// A milestone reminder was tapped: the count, which names the milestone.
        case anniversary
    }
    var pendingRoute: Route?

    /// When a send of ours was last confirmed delivered — Home's footer says so briefly.
    private(set) var sendConfirmedAt: Date?

    /// A tapped invite held until `WelcomeView` has a display name — see `acceptInvite(name:)`.
    var pendingInvite: CKShare.Metadata?

    /// Guideline 1.2: nothing else shows until the current terms are agreed to.
    var termsAccepted: Bool
    /// `updatedAt` of a reported partner status — see `SharedStore.hiddenPartnerStatusAt`.
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
    /// What was last handed to the system, so `reload` reschedules only on change.
    @ObservationIgnored private var scheduledReminders: [MilestoneReminderPlan.Reminder]?
    @ObservationIgnored private var reminderSync: Task<Void, Never>?
    @ObservationIgnored private var isCleaningSubscriptions = false
    /// The gallery marked moments seen without reloading the widgets each page.
    @ObservationIgnored private var widgetReloadOwed = false

    // State of the extensions in the AppModel+ files (an extension can't hold any).

    /// The on-device word filter over the partner's text; widgets read the same switch.
    var contentFilterEnabled: Bool {
        didSet {
            guard oldValue != contentFilterEnabled else { return }
            store.contentFilterEnabled = contentFilterEnabled
            SharedStore.reloadWidgets()
        }
    }
    /// When readiness was last asked; `nil` forces the next fetch to ask again.
    @ObservationIgnored var readinessCheckedAt: Date?

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
    init(store: SharedStore = .shared, backend: (any SyncBackend)? = nil) {
        self.store = store
        let backendProvider: () -> any SyncBackend = backend.map { fixed in { fixed } } ?? { Backend.current }
        self.backendProvider = backendProvider
        self.outbox = Outbox(store: store,
                             index: .shared,
                             statusLog: .shared,
                             backend: backendProvider,
                             hasMedia: { MomentStore.shared.hasMedia(for: $0) },
                             deleteMedia: { MomentStore.shared.delete(id: $0) },
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
        self.partnerLeftNoticeDismissed = store.partnerLeftNoticeDismissed
        self.milestoneRemindersEnabled = store.milestoneRemindersEnabled
        // A retried send confirms like a first one.
        outbox.uploaded = { [weak self] _ in self?.noteUploaded() }
        refreshRecentStatusesIfNeeded()
    }

    // MARK: - Derived

    /// The partner's name as shown everywhere — filtered like any of their text.
    var partnerName: String { snapshot.moderatedPartnerName }

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

    /// Looked at, or — for a memo — listened to.
    /// `reloadWidgets: false` while paging the gallery: one reload when it
    /// closes (`flushWidgetReload`), not one per page.
    func markSeen(_ moment: Moment, reloadWidgets: Bool = true) {
        guard !moment.seen, !moment.fromMe else { return }
        history = Self.shownHistory(MomentIndex.shared.markSeen(ids: [moment.id]))
        // The widget's unheard-memo badge is a snapshot field; this is what clears it.
        if store.refreshDerived(reloadWidgets: reloadWidgets), !reloadWidgets { widgetReloadOwed = true }
        snapshot = store.snapshot
        if readReceiptsEnabled, isPaired {
            store.mutate(reloadWidgets: false) { $0.receiptsDirty = true }
            outbox.scheduleReceiptFlush()
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
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        startNetworkMonitoring()
        // Cold-start link taps land here: the scene delegate ran before any view could listen.
        if let invite = InviteInbox.shared.take() {
            receiveInvite(invite)
        }
        // One receipt publish per launch even when nothing marked itself dirty:
        // covers moments seen before receipts existed and heals lost publishes —
        // with receipts off too, so a retraction a stale write overtook is re-sent.
        // Before any await: the scene's own refresh may run its recovery pass first.
        if isPaired { store.mutate(reloadWidgets: false) { $0.receiptsDirty = true } }
        await refreshReadiness()
        guard isPaired else { return }
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
        // The scene turning active refreshes too: one fetch between them, and
        // the recovery pass (the receipts above) either way.
        if let fetched = lastFetchSucceededAt,
           Date().timeIntervalSince(fetched) < AppConfig.launchRefreshCoalesceWindow {
            Task { await recoverAfterRefresh() }
        } else {
            await refresh(noteIfBusy: false)
        }
    }

    /// `.pairingDidChange`: the store moved outside this model's calls (the Siri
    /// heart, a background refresh that found the link ended). Re-read, then fetch.
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
        update(\.history, Self.shownHistory(MomentIndex.shared.load()))
        refreshRecentStatusesIfNeeded()
        syncMilestoneReminders()
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
                              _ call: @escaping @Sendable (any SyncBackend) async throws -> T) async throws -> T {
        let backend = backend
        return try await withDeadline(seconds) { try await call(backend) }
    }

    // MARK: - Media on demand

    /// Older entries keep metadata but not media files; fetches the file back from CloudKit on demand.
    func ensureMedia(for moment: Moment) async -> Bool {
        if MomentStore.shared.hasMedia(for: moment) { return true }
        do {
            try await backend.fetchMedia(for: moment)
            return MomentStore.shared.hasMedia(for: moment)
        } catch {
            log.error("Couldn't fetch media for \(moment.id): \(error.localizedDescription)")
            return false
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

    /// The library grid's version of `ensureMedia`: just the thumbnail, fetched
    /// as the tile scrolls into view, batched with its neighbours. Bounded per
    /// batch: the recovery pass awaits this. `false` when it still isn't on disk.
    func ensureThumbnail(for moment: Moment) async -> Bool {
        if MomentStore.shared.hasThumbnail(for: moment.id) { return true }
        guard !moment.isVoice else { return false }
        return await thumbnailFetcher.thumbnail(for: moment)
    }

    // MARK: - Status

    /// Whole seconds: a fractional stamp never equals its own stored copy (invariant 14).
    private func statusTimestamp() -> Date {
        Date().wholeSeconds
    }

    func setStatus(emoji: String, message: String, isCelebration: Bool = false) async {
        let payload = StatusPayload(
            emoji: emoji,
            // Capped here too: the banner reply bypasses the composer's field.
            message: String(message.trimmingCharacters(in: .whitespacesAndNewlines)
                                .prefix(AppConfig.statusMessageMaxLength)),
            displayName: snapshot.mine?.displayName ?? "",
            updatedAt: statusTimestamp(),
            nudgeCount: snapshot.mine?.nudgeCount ?? 0,
            lastNudgeAt: snapshot.mine?.lastNudgeAt,
            isCelebration: isCelebration
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

        guard paired else { return }
        statusSendsInFlight += 1
        defer { statusSendsInFlight -= 1 }
        do {
            // The backend marks it published, against the then-current status (invariant 16).
            try await bounded { try await $0.publish(payload) }
            outbox.noteSendSucceeded()
            reload()
            AccessibilityNotification.Announcement(String(localized: "Status sent to \(partnerName)")).post()
        } catch {
            presentSendFailure(error, noun: String(localized: "status update"))
            reload()
            AccessibilityNotification.Announcement(String(localized: "Status saved. It sends once iCloud can be reached.")).post()
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
                try await bounded { try await $0.publish(payload, logged: logged) }
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
    func sendNudge() async {
        // Claimed before the await: the store's cooldown reaches this model only once the call returns.
        guard canNudge, !isSendingNudge else { return }
        isSendingNudge = true
        defer { isSendingNudge = false }
        do {
            if try await backend.sendNudge() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AccessibilityNotification.Announcement(String(localized: "Nudge sent")).post()
            }
            reload()
        } catch {
            // `CloudSync.sendNudge` stamped `lastNudgeFailedAt`: the heart itself
            // says it didn't send, like the lock-screen one.
            log.error("Nudge failed: \(error.localizedDescription, privacy: .public)")
            AccessibilityNotification.Announcement(String(localized: "Nudge didn't send")).post()
            reload()
        }
    }

    // MARK: - Moments

    /// Filed locally first so the UI and widget update at once, then uploaded.
    /// A failed upload leaves the local copy in place.
    func sendMoment(image: UIImage, kind: Moment.Kind, caption: String) async {
        let moment = newMoment(kind: kind, caption: caption)
        let id = moment.id
        await send(moment, taskName: "moment-upload",
                   saveFailure: String(localized: "Couldn't save that moment")) {
            try MomentStore.shared.write(image, id: id)
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
               caption: String(caption.trimmingCharacters(in: .whitespacesAndNewlines)
                                   .prefix(AppConfig.captionMaxLength)),
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
        isBusy = true
        defer { isBusy = false }
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
        store.record(moment)
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard isPaired else { return }
        do {
            try await outbox.upload(moment, taskName: taskName)
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
        guard isPaired, refreshGate.begin(noteIfBusy: false) else { return nil }
        store.clearChangeTokens()
        do {
            try await SyncRunner.refresh(announce: false)
        } catch {
            // A refresh asked for meanwhile still runs.
            let pending = refreshGate.takeRequest()
            refreshGate.end()
            if pending { Task { await refresh() } }
            reload()
            log.error("History resync failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        recentStatusesKey = nil
        reload()
        let found = pendingUploadCount
        // Outside the gate: sending isn't fetching, and refreshes needn't wait on it.
        let pending = refreshGate.takeRequest()
        refreshGate.end()
        if pending { Task { await refresh() } }
        await outbox.retryPendingUploads(automatic: false)
        reload()
        return found
    }

    /// A send of ours is confirmed on the server (the outbox marked it).
    private func noteUploaded() {
        history = Self.shownHistory(MomentIndex.shared.load())
        sendConfirmedAt = Date()
    }

    /// What the screens list: a kind from a newer build stays in the index, so
    /// an update shows it, but there's nothing here to draw it with.
    private static func shownHistory(_ all: [Moment]) -> [Moment] {
        all.filter(\.kind.isSupported)
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
        let now = statusTimestamp()
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
        // A full iCloud already names itself in the footer.
        if pendingSendCount > 0, storageFullAt == nil {
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
        let outbox = outbox
        await Self.withUploadProtection("receipts") { await outbox.flushReceiptsNow() }
    }

    // MARK: - Status history

    /// Your own last few distinct statuses, newest first — the picker's "Recent".
    /// Own words only, so no moderation applies.
    func recentOwnStatuses(limit: Int = AppModel.recentStatusLimit) -> [StatusHistoryEntry] {
        guard limit != Self.recentStatusLimit else { return recentStatuses }
        return StatusHistoryEntry.recentOwn(in: StatusHistoryLog.shared.load(), limit: limit)
    }

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

    /// The rolling status log, newest first, with a reported or filtered partner
    /// status shown as such — loaded on demand by the history sheet.
    func loadStatusHistory() -> [StatusHistoryEntry] {
        let reportedAt = hiddenPartnerStatusAt
        let filterOn = contentFilterEnabled
        return StatusHistoryLog.shared.load().map { $0.moderated(reportedAt: reportedAt, filterEnabled: filterOn) }
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
