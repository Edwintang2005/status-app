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

    private let store: SharedStore
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "AppModel")

    private(set) var snapshot: Snapshot
    private(set) var isPaired: Bool
    private(set) var role: PairRole?
    /// Owner side: invite revoked from Settings or Diagnostics.
    private(set) var inviteClosed: Bool
    private(set) var isBusy = false
    /// The fetch only (`RefreshGate`): a request mid-fetch runs it once more.
    private var refreshGate = RefreshGate()
    var isRefreshing: Bool { refreshGate.isRunning }
    /// The post-fetch recovery pass (republishes, retries, receipts) — outside
    /// `isRefreshing`, so a stalled send can't hold off the next fetch.
    @ObservationIgnored private var recoveryGate = RefreshGate()
    /// The offline-send loops, over the same store and backend as this model.
    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored private let backendProvider: () -> any SyncBackend
    private var backend: any SyncBackend { backendProvider() }
    /// The home footer shows "Sending…" while it runs.
    var isRetryingUploads: Bool { outbox.isRetryingUploads }
    /// When a send last failed on a full iCloud (`SendFailure.storageFull`).
    var storageFullAt: Date? { outbox.storageFullAt }

    /// Fires a refresh on the offline→online edge — the only trigger that watches the network itself.
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Starts `true` so the monitor's immediate first callback doesn't double up with `onLaunch`'s refresh.
    @ObservationIgnored private var networkWasSatisfied = true
    /// No network path — display only (Home's card, the gallery's wording). Sends
    /// never gate on it: it goes stale while suspended, and a banner action wakes
    /// the app before the monitor catches up. They try, and fail quietly offline.
    private(set) var isOffline = false
    /// The path is down because mobile data is off for this app — the one cause the user can fix.
    private(set) var mobileDataDenied = false
    @ObservationIgnored private var offlineShowTask: Task<Void, Never>?
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    /// Whichever refresh last fetched — the reconnect catch-up judges by it, not by who ran it.
    @ObservationIgnored private var lastFetchSucceededAt: Date?
    /// Status publishes this model has in flight — not yet "waiting to send".
    private var statusSendsInFlight = 0
    /// The footer's tap-to-retry is running.
    private(set) var isSendingNow = false
    /// Owner side: the link to hand to the partner. Kept after the invite
    /// closes — the same link re-admits the existing partner on a new phone.
    /// Seeded from the store so it survives a relaunch — see `refreshInviteURL()`.
    private(set) var inviteURL: URL?
    /// A pairing found on the server with no local state — a fresh install on
    /// a new phone. The pairing screen offers it as "Rejoin".
    private(set) var rejoinablePairing: (role: PairRole, zoneID: CKRecordZone.ID)?
    /// The server has no share at all (vs. one that was closed) — keeps Settings from spinning forever.
    private(set) var inviteLinkUnavailable = false
    /// Non-nil when the backend can't work — no iCloud account, and so on.
    private(set) var readinessMessage: String?
    /// Full moment history, newest first, from `MomentIndex` (the snapshot only carries the newest each way).
    private(set) var history: [Moment] = []

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
    /// A status publish is in flight, so an unpublished status isn't yet "not sent".
    var isPublishingStatus: Bool { statusSendsInFlight > 0 }

    /// A tapped invite held until `WelcomeView` has a display name — see `acceptInvite(name:)`.
    private(set) var pendingInvite: CKShare.Metadata?

    /// Guideline 1.2: nothing else shows until the current terms are agreed to.
    private(set) var termsAccepted: Bool
    /// `updatedAt` of a reported partner status — see `SharedStore.hiddenPartnerStatusAt`.
    private(set) var hiddenPartnerStatusAt: Date?
    /// Owner side: the "when did you two begin?" prompt is owed — see `SharedStore.anniversaryPromptPending`.
    private(set) var anniversaryPromptPending = false
    /// `HomeView` has a sheet up. Root-level presentations (the anniversary
    /// prompt) wait for it to close rather than being dropped by SwiftUI.
    var homeSheetShowing = false
    /// Owner side: people other than the owner on the share, from the last
    /// check (`checkShareMembers`). More than one is the stranger warning.
    private(set) var shareMemberCount: Int?
    @ObservationIgnored private var shareMembersCheckedAt: Date?
    private(set) var closeLinkPromptDismissed: Bool
    private(set) var widgetTipDismissed: Bool
    /// Home's "notifications are off" card, re-read on every foregrounding.
    private(set) var notificationsNotice: NotificationsNotice?
    /// A heart is on its way. The app's nudge has no deadline (its cooldown
    /// release lives in `CloudSync.sendNudge`), so the button holds still meanwhile.
    private(set) var isSendingNudge = false
    /// `wordsAt` of the partner status whose filter-hidden words were revealed
    /// here — until they change it.
    private var revealedPartnerWordsAt: Date?
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

    /// Store and backend are injectable so previews run against a throwaway
    /// defaults suite; `nil` backend is `Backend.current`, looked up per call.
    /// Only this model's own sends use it: `SyncRunner`, the index and the
    /// media store stay process-wide.
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
        store.partnerLeftNoticeDismissed = snapshot.partnerLeftAt
        partnerLeftNoticeDismissed = snapshot.partnerLeftAt
    }

    /// Whether this person has ever set a name — the one gate before the rest
    /// of the app, since everything sent carries it and there's no sensible default.
    var hasName: Bool {
        snapshot.mine?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var myDisplayName: String {
        get { snapshot.mine?.displayName ?? "" }
        set { updateMyDisplayName(newValue) }
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
        let owesReceipt = readReceiptsEnabled && isPaired
        // The widget's unheard-memo badge is a snapshot field; this is what clears it.
        let refreshed = store.refreshDerived(reloadWidgets: reloadWidgets) { snapshot in
            if owesReceipt { snapshot.receiptsDirty = true }
        }
        if refreshed.changed, !reloadWidgets { widgetReloadOwed = true }
        snapshot = refreshed.snapshot
        if owesReceipt { outbox.scheduleReceiptFlush() }
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

    // MARK: - Onboarding

    /// Records the name from the welcome screen; publishing waits for pairing (no zone yet).
    func setName(_ name: String) {
        updateMyDisplayName(name)
    }

    /// Invite sender's name — only available when they're discoverable by
    /// Apple Account, so the joining screen has to read well without it.
    var pendingInviteOwnerName: String? {
        guard let components = pendingInvite?.ownerIdentity.nameComponents else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .short)
        return name.isEmpty ? nil : name
    }

    /// Called when a share link opens the app; held so the welcome screen can ask for a name first.
    /// Refused while paired: joining a second zone would break the change tokens and mix galleries.
    func receiveInvite(_ metadata: CKShare.Metadata) {
        guard !isPaired else {
            let zoneID = metadata.share.recordID.zoneID
            if let pairing = store.pairing,
               zoneID.zoneName == pairing.zoneName,
               zoneID.ownerName == pairing.zoneOwnerName {
                // Our own share's link: not a new pairing, a confirmation — how
                // a partner left `pending` by the promote handshake accepts
                // their private seat.
                Task {
                    try? await CloudSync.shared.reacceptShare(metadata)
                    await refresh()
                }
            } else {
                errorTitle = String(localized: "Already linked")
                errorMessage = String(localized: "You're already linked with \(partnerName). To join a new invite, unlink first in Settings.")
            }
            return
        }
        pendingInvite = metadata
    }

    /// The name the invitee entered on the joining screen, then the join.
    func acceptInvite(name: String) async {
        guard let metadata = pendingInvite else { return }
        isBusy = true
        defer { isBusy = false }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateMyDisplayName(trimmed)

        do {
            try await CloudSync.shared.acceptShare(metadata, displayName: trimmed)
            pendingInvite = nil
            reload()
            await NotificationManager.requestAuthorizationIfNeeded()
            await refresh()
        } catch {
            // Invite kept — the link is still the way in. Reload first: `acceptShare`
            // commits the pairing before its bootstrap publish, so the store may already say paired.
            reload()
            present(error, title: String(localized: "Couldn't join"))
        }
    }

    /// Backing out of a join — the invite is dropped.
    func declineInvite() {
        pendingInvite = nil
    }

    /// Looks for a pairing the server still holds for this account — a fresh
    /// install on a new phone can rejoin it without a new invite link.
    func checkForRejoinablePairing() async {
        guard !isPaired, pendingInvite == nil else { return }
        rejoinablePairing = await CloudSync.shared.discoverExistingPairing()
    }

    /// Recommits the discovered pairing under the name from the pairing screen.
    func rejoin(name: String) async {
        guard let found = rejoinablePairing else { return }
        isBusy = true
        defer { isBusy = false }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateMyDisplayName(trimmed)

        do {
            try await CloudSync.shared.rejoin(role: found.role,
                                              zoneID: found.zoneID,
                                              displayName: trimmed)
            rejoinablePairing = nil
            reload()
            await NotificationManager.requestAuthorizationIfNeeded()
            await refresh()
        } catch {
            // Same shape as `acceptInvite`: `rejoin` commits the pairing before
            // its bootstrap publish, so the store may already say paired.
            reload()
            present(error, title: String(localized: "Couldn't rejoin"))
        }
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
            let backend = backend
            let store = store
            Task {
                do {
                    try await withDeadline(AppConfig.publishDeadline) { try await backend.registerSubscription() }
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

    /// Called when the scene delegate has accepted an invite.
    func reloadFromStore() async {
        reload()
        // First moment the notification prompt makes sense — a nudge is now receivable.
        await NotificationManager.requestAuthorizationIfNeeded()
        await refresh()
    }

    /// The store changed under this model's own refresh: re-read, no fetch.
    func reloadLocally() {
        reload()
    }

    private func reload() {
        snapshot = store.snapshot
        isPaired = store.pairing != nil
        role = store.pairing?.role
        inviteClosed = store.inviteClosed
        // The closed link is kept on purpose — see `refreshInviteURL`.
        inviteURL = store.inviteURL
        hiddenPartnerStatusAt = store.hiddenPartnerStatusAt
        anniversaryPromptPending = store.anniversaryPromptPending
        closeLinkPromptDismissed = store.closeLinkPromptDismissed
        if !isPaired {
            shareMemberCount = nil
            shareMembersCheckedAt = nil
            invitePostureChecked = false
        }
        history = Self.shownHistory(MomentIndex.shared.load())
        syncMilestoneReminders()
    }

    // MARK: - Safety (guideline 1.2)

    func acceptTerms() {
        store.acceptedTermsVersion = AppConfig.termsVersion
        termsAccepted = true
    }

    /// The on-device word filter over the partner's text; widgets read the same switch.
    var contentFilterEnabled: Bool {
        didSet {
            guard oldValue != contentFilterEnabled else { return }
            store.contentFilterEnabled = contentFilterEnabled
            SharedStore.reloadWidgets()
        }
    }

    /// The current partner status has been reported: its text stays hidden.
    var isPartnerStatusReported: Bool {
        guard let theirs = snapshot.theirs, let hidden = hiddenPartnerStatusAt else { return false }
        return theirs.wordsAt == hidden || theirs.updatedAt == hidden
    }

    /// The filter-hidden words of their current status were revealed on this iPhone.
    var partnerStatusRevealed: Bool {
        guard let revealed = revealedPartnerWordsAt else { return false }
        return snapshot.theirs?.wordsAt == revealed
    }

    /// "Show hidden text": the words are on screen now, so the read receipt may go.
    func revealPartnerStatus() {
        revealedPartnerWordsAt = snapshot.theirs?.wordsAt
        markPartnerStatusSeen()
    }

    /// Removes the moment from this device for good and mails the report.
    /// Only ever the partner's — there's nothing to report about your own.
    func report(_ moment: Moment) {
        guard !moment.fromMe else { return }
        var hidden = store.hiddenMomentIDs
        hidden.insert(moment.id)
        store.hiddenMomentIDs = hidden
        MomentIndex.shared.remove(id: moment.id)
        MomentStore.shared.delete(id: moment.id)
        store.refreshDerived()
        reload()
        sendReport(Report.Details(kind: moment.noun,
                                  identifier: moment.id,
                                  senderName: moment.senderName,
                                  text: moment.caption,
                                  pairing: store.pairing,
                                  reporterName: myDisplayName))
    }

    /// Hides the partner's current status text (until they set another) and mails the report.
    func reportPartnerStatus() {
        guard let theirs = snapshot.theirs else { return }
        // The words' date, so the partner renaming themselves doesn't unhide them.
        store.hiddenPartnerStatusAt = theirs.wordsAt
        hiddenPartnerStatusAt = theirs.wordsAt
        SharedStore.reloadWidgets()
        sendReport(Report.Details(kind: "status",
                                  identifier: "status at \(theirs.updatedAt.formatted(.iso8601))",
                                  senderName: theirs.displayName,
                                  text: "\(theirs.emoji) \(theirs.message)",
                                  pairing: store.pairing,
                                  reporterName: myDisplayName))
    }

    /// Blocks the partner: everything they sent leaves this iPhone at once, the
    /// link ends, their invites are refused from now on, and the developer is
    /// told. Local removal is not conditional on iCloud — a block must land
    /// even offline — so, unlike `unlink`, a failed cloud step is reported
    /// afterwards rather than stopping it.
    func block() async {
        isBusy = true
        defer { isBusy = false }
        let name = partnerName
        let status = snapshot.theirs
        let pairing = store.pairing
        let names = await CloudSync.shared.recordBlockedPartner()

        var cloudProblem: String?
        do {
            try await backend.unpair()
        } catch {
            cloudProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        finishUnlink(startingOver: false)

        sendReport(Report.Details(kind: "blocked user",
                                  identifier: names.isEmpty ? "(unknown record)" : names.joined(separator: ", "),
                                  senderName: name,
                                  text: status.map { "\($0.emoji) \($0.message)" } ?? "",
                                  pairing: pairing,
                                  reporterName: myDisplayName))
        if let cloudProblem {
            errorTitle = String(localized: "Blocked, not yet unlinked")
            errorMessage = String(localized: "\(name) is blocked and everything they sent has been removed from this iPhone. iCloud couldn't be reached to finish the unlink (\(cloudProblem)), so what you sent may still be in the shared space; try Settings → Unlink later if it reappears.")
        }
    }

    /// Opens Mail with the report. Without a mail account the text goes to the
    /// clipboard instead (this iPhone only, expiring), with the address to send it to.
    private func sendReport(_ details: Report.Details) {
        let body = Report.body(for: details)
        guard let url = Report.mailURL(for: details) else { return }
        UIApplication.shared.open(url) { opened in
            guard !opened else { return }
            Task { @MainActor in
                Clipboard.copy(text: body, localOnly: true)
                self.noticeMessage = String(localized: "Mail isn't set up on this iPhone, so the report has been copied to your clipboard for the next \(Clipboard.lifetimeMinutes) minutes. Please email it to \(AppConfig.supportEmail).")
            }
        }
    }

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
    private func restoreLatestThumbnailIfMissing() async {
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

    // MARK: - Sync

    /// PairingView's iCloud warning. Re-checked on every foregrounding, not just
    /// launch — the fix happens in the Settings app, so the user returns expecting it noticed.
    private func refreshReadiness() async {
        if case .unavailable(let message) = await backend.readiness() {
            readinessMessage = message
        } else {
            readinessMessage = nil
        }
        readinessCheckedAt = Date()
    }

    /// When readiness was last asked; `nil` forces the next fetch to ask again.
    @ObservationIgnored private var readinessCheckedAt: Date?

    /// Refreshes on the offline→online edge — `refresh()` already handles
    /// offline calls and re-entrancy; the job here is ignoring path churn while up.
    /// Delivered on the main queue so updates apply in the order they happened.
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.networkPathChanged(path) }
        }
        pathMonitor.start(queue: .main)
    }

    /// Only `.unsatisfied` is down: `.requiresConnection` (an on-demand VPN, a
    /// dormant radio) comes up as soon as something uses it.
    private func networkPathChanged(_ path: NWPath) {
        let down = path.status == .unsatisfied
        let cameBackOnline = !down && !networkWasSatisfied
        networkWasSatisfied = !down
        offlineShowTask?.cancel()
        if down {
            mobileDataDenied = path.unsatisfiedReason == .cellularDenied
            // Shown after a moment: a Wi-Fi↔cellular handoff blips for under a second.
            offlineShowTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(AppConfig.offlineCardDelay))
                guard !Task.isCancelled, let self, !self.networkWasSatisfied else { return }
                self.setOffline(true)
            }
        } else {
            setOffline(false)
        }
        if cameBackOnline {
            log.notice("Network is back; refreshing.")
            catchUpTask?.cancel()
            catchUpTask = Task { [weak self] in await self?.catchUpAfterReconnect() }
        }
    }

    private func setOffline(_ offline: Bool) {
        #if DEBUG
        // Demo mode's backend never touches the network.
        if DemoMode.isActive { return }
        #endif
        if isOffline != offline { isOffline = offline }
    }

    /// The first refresh after the path returns often beats DNS or a VPN; one
    /// failure must not leave queued sends waiting for the next foreground.
    /// Done once a fetch since the edge worked (whoever ran it — a request that
    /// joined a running refresh still retries if that one failed) and nothing is
    /// left queued: a send pass can still hit the flap after a good fetch.
    private func catchUpAfterReconnect() async {
        let since = Date()
        for delay in AppConfig.reconnectRetryDelays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, networkWasSatisfied, isPaired else { return }
            await refresh()
            if let fetched = lastFetchSucceededAt, fetched >= since, pendingSendCount == 0 { return }
        }
    }

    /// The system reported an iCloud account change: make the next readiness
    /// check look the account up for real, then refresh.
    func accountDidChange() async {
        await backend.noteAccountChanged()
        readinessCheckedAt = nil
        await refresh()
    }

    /// Returns once the fetch lands; the recovery pass it unlocks runs on after,
    /// so pull-to-refresh doesn't wait on uploads.
    func refresh(noteIfBusy: Bool = true) async {
        guard refreshGate.begin(noteIfBusy: noteIfBusy) else { return }
        var fetched = false
        repeat {
            if await fetchOnce() { fetched = true }
        } while refreshGate.takeRequest()
        refreshGate.end()
        // A working refresh is the recovery moment for sends that died offline.
        if fetched {
            Task { await recoverAfterRefresh() }
        }
    }

    /// Coalesced like the fetch: a pass asked for mid-pass runs once more.
    private func recoverAfterRefresh() async {
        guard isPaired, recoveryGate.begin() else { return }
        repeat {
            await sendQueued(automatic: true)
            await outbox.flushReceipts()
            await restoreLatestThumbnailIfMissing()
            await checkShareMembers(throttled: true)
            await checkInstalledWidgets()
        } while recoveryGate.takeRequest()
        recoveryGate.end()
    }

    /// Everything queued, in order, re-read after each step: the footer, the
    /// status row and the tiles' clocks follow along.
    private func sendQueued(automatic: Bool) async {
        if await outbox.republishStatus(automatic: automatic) { reload() }
        if await outbox.republishAnniversary(automatic: automatic) { reload() }
        if await outbox.republishAnniversaryRequest(automatic: automatic) { reload() }
        // Before the upload retry: the clear and a retry never overlap.
        if await outbox.advanceFreshStart() { reload() }
        if await outbox.retryPendingUploads(automatic: automatic) { reload() }
    }

    /// One fetch and reload; `false` when it failed or there was nothing to fetch for.
    private func fetchOnce() async -> Bool {
        // Re-checked when paired too: this is what notices an iCloud account
        // switch (which drops the reused answer). One just asked is reused.
        if Date().timeIntervalSince(readinessCheckedAt ?? .distantPast) >= AppConfig.readinessReuseWindow {
            await refreshReadiness()
        }
        guard isPaired else {
            await cleanUpSubscriptionsIfNeeded()
            return false
        }
        do {
            try await SyncRunner.refresh()
            reload()
            lastFetchSucceededAt = Date()
            // A fetch that worked is proof the monitor's "down" is stale.
            offlineShowTask?.cancel()
            setOffline(false)
            return true
        } catch {
            // The backend may have unlinked us (a vanished zone means the other
            // person ended things), so re-read local state either way.
            reload()
            if let sync = error as? SyncError, case .linkEnded = sync {
                // The one refresh failure that is really a message from another person.
                errorTitle = String(localized: "Link ended")
                errorMessage = sync.errorDescription
            }
            // Other refresh failures are routine; the "Synced …" footer already shows staleness.
            log.error("Refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Status

    /// Whole-second stamp for `StatusPayload.updatedAt`: persisted dates
    /// round-trip through ISO-8601 JSON, which drops fractional seconds, so a
    /// fractional stamp never equals its own stored copy — breaking the
    /// publish-flag check and the status-history dedup.
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
            let backend = backend
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publish(payload) }
            store.mutate(reloadWidgets: false) { $0.markStatusPublished(payload) }
            outbox.noteSendSucceeded()
            reload()
            AccessibilityNotification.Announcement(String(localized: "Status sent to \(partnerName)")).post()
        } catch {
            presentSendFailure(error, noun: String(localized: "status update"))
            reload()
            AccessibilityNotification.Announcement(String(localized: "Status saved. It sends once iCloud can be reached.")).post()
        }
    }

    private func updateMyDisplayName(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = statusTimestamp()
        let paired = isPaired
        // Built from the store's copy inside the lock: the model's may predate a
        // heart sent from the lock screen, or a status another device set.
        let payload = store.mutate {
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
        }.mine ?? .initial(displayName: trimmed)
        reload()

        guard paired else { return }
        // Not logged: the status didn't change, only the name on it — unless the
        // status itself never made it into the log (set offline, then renamed).
        let logged = store.snapshot.myStatusLoggedAt != payload.wordsAt
        let backend = backend
        statusSendsInFlight += 1
        Task { [payload] in
            defer { statusSendsInFlight -= 1 }
            do {
                try await withDeadline(AppConfig.publishDeadline) { try await backend.publish(payload, logged: logged) }
                store.mutate(reloadWidgets: false) { $0.markStatusPublished(payload) }
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
        // Claimed before the await: the store's cooldown only reaches this
        // model when the call returns, and a second tap meanwhile sent a second heart.
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

    /// Writes the image to the App Group first so the UI and widget update
    /// instantly, then uploads. A failed upload leaves the local copy in place.
    func sendMoment(image: UIImage, kind: Moment.Kind, caption: String) async {
        isBusy = true
        defer { isBusy = false }

        // `senderName` is captured at send time (older moments keep the name you had then).
        // Pending only when paired — an unpaired send has nothing to retry.
        let moment = Moment(
            kind: kind,
            caption: String(caption.trimmingCharacters(in: .whitespacesAndNewlines)
                                .prefix(AppConfig.captionMaxLength)),
            senderName: snapshot.mine?.displayName ?? "",
            fromMe: true,
            uploaded: !isPaired
        )

        do {
            try MomentStore.shared.write(image, id: moment.id)
        } catch {
            present(error, title: String(localized: "Couldn't save that moment"))
            return
        }

        store.record(moment)
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard isPaired else { return }
        do {
            try await outbox.upload(moment, taskName: "moment-upload")
        } catch {
            presentSendFailure(error, noun: moment.noun)
        }
    }

    /// Runs an upload inside a background-task assertion so locking the phone
    /// doesn't suspend the process mid-upload and silently lose the send. The
    /// post-upload bookkeeping belongs *inside* `body` too: ending the assertion
    /// is what lets iOS suspend, and a shared-container file lock taken right
    /// after is a `0xdead10cc` kill (TestFlight crash, 2026-09).
    static func withUploadProtection<T>(_ name: String,
                                        _ body: () async throws -> T) async rethrows -> T {
        let assertion = BackgroundAssertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            assertion.end()
        }
        defer { assertion.end() }
        return try await body()
    }

    /// Same shape as `sendMoment`: filed locally first, then uploaded.
    /// `fileURL` is **moved**, not copied — the caller must not use it afterwards.
    func sendVoiceMemo(fileURL: URL,
                       duration: TimeInterval,
                       waveform: [Double],
                       caption: String) async {
        isBusy = true
        defer { isBusy = false }

        let moment = Moment(
            kind: .voice,
            caption: String(caption.trimmingCharacters(in: .whitespacesAndNewlines)
                                .prefix(AppConfig.captionMaxLength)),
            senderName: snapshot.mine?.displayName ?? "",
            fromMe: true,
            uploaded: !isPaired,
            duration: duration,
            waveform: waveform
        )

        do {
            try MomentStore.shared.adoptAudio(from: fileURL, id: moment.id)
        } catch {
            present(error, title: String(localized: "Couldn't save that voice memo"))
            return
        }

        store.record(moment)
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard isPaired else { return }
        do {
            try await outbox.upload(moment, taskName: "voice-memo-upload")
        } catch {
            presentSendFailure(error, noun: moment.noun)
        }
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

    /// Owner only. Written locally first (and marked unpublished in the same
    /// mutate), then pushed; a failure is quiet because `Outbox.republishAnniversary`
    /// carries it over on the next refresh. `nil` removes the date on both phones.
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

        do {
            let backend = backend
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publishAnniversary(anniversary) }
            store.mutate(reloadWidgets: false) { $0.markAnniversaryPublished(anniversary) }
            reload()
        } catch {
            outbox.noteSendFailed(error)
            log.error("Anniversary publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The prompt after creating the link was skipped; Settings still has the row.
    func dismissAnniversaryPrompt() {
        store.anniversaryPromptPending = false
        anniversaryPromptPending = false
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

    /// Same shape as `setAnniversary`: filed locally and marked unpublished in
    /// one mutate, pushed, and carried over by the next refresh on failure.
    func requestAnniversary() async {
        guard canRequestAnniversary else { return }
        // Whole seconds, like every persisted date (invariant 14).
        let now = statusTimestamp()
        store.mutate(reloadWidgets: false) {
            $0.anniversaryRequestedAt = now
            $0.anniversaryRequestPublished = false
        }
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        do {
            let backend = backend
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publishAnniversaryRequest(at: now) }
            store.mutate(reloadWidgets: false) { $0.markAnniversaryRequestPublished(now) }
            reload()
        } catch {
            outbox.noteSendFailed(error)
            log.error("Anniversary request publish failed: \(error.localizedDescription, privacy: .public)")
        }
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
        reload()
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
            Task { await flushReceiptsIfNeeded() }
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
        store.mutate(reloadWidgets: false) { changed = $0.stampPartnerStatusSeen(shown, at: Date()) }
        guard changed else { return }
        snapshot = store.snapshot
        outbox.scheduleReceiptFlush()
    }

    /// Going to the background: what the debounce was holding goes now,
    /// inside a background task so suspension can't cut it off.
    func flushReceiptsForBackground() async {
        guard isPaired else { return }
        let outbox = outbox
        await Self.withUploadProtection("receipts") { await outbox.flushReceiptsNow() }
    }

    /// Publishes this device's receipts when they're dirty; the outbox claims
    /// the flag before the network call and re-sets it on failure.
    func flushReceiptsIfNeeded() async {
        await outbox.flushReceipts()
    }

    // MARK: - Status history

    /// Your own last few distinct statuses, newest first — the picker's "Recent".
    /// Own words only, so no moderation applies.
    func recentOwnStatuses(limit: Int = 8) -> [StatusHistoryEntry] {
        StatusHistoryEntry.recentOwn(in: StatusHistoryLog.shared.load(), limit: limit)
    }

    /// The rolling status log, newest first, with a reported or filtered partner
    /// status shown as such — loaded on demand by the history sheet.
    func loadStatusHistory() -> [StatusHistoryEntry] {
        let reportedAt = hiddenPartnerStatusAt
        let filterOn = contentFilterEnabled
        return StatusHistoryLog.shared.load().map { $0.moderated(reportedAt: reportedAt, filterEnabled: filterOn) }
    }

    // MARK: - Pairing

    /// `RootView`'s own sheets over Home: the invite link and the date prompt
    /// (mirrors that sheet's condition).
    var rootSheetShowing: Bool {
        presentedInvite != nil
            || ((anniversaryPromptPending || anniversaryRequestPending) && canEditAnniversary && !homeSheetShowing)
    }

    /// The old space the replace dialog would delete has someone on it.
    private(set) var replacingSpaceHasPartner = false

    /// `replacingExisting` only after the user confirmed deleting the old space.
    func createInvite(replacingExisting: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await CloudSync.shared.createPairInvite(displayName: myDisplayName,
                                                                  replacingExisting: replacingExisting)
            setInviteURL(url)
            reload()
            // After `reload()`, which flips `isPaired` and dismisses the pairing screen.
            presentedInvite = InviteLink(url: url)
            // Owed once the link sheet closes — see `RootView`.
            store.anniversaryPromptPending = true
            anniversaryPromptPending = true
            await NotificationManager.requestAuthorizationIfNeeded()
        } catch SyncError.existingPairing(let someoneOnIt) {
            // Nothing written: offer Rejoin, or the confirmed replace — asked
            // only once discovery says whether Rejoin is there to offer.
            await checkForRejoinablePairing()
            replacingSpaceHasPartner = someoneOnIt
            confirmingReplacePairing = true
        } catch {
            // `createPairInvite` commits the pairing before its bootstrap publish;
            // reload so the store and this model can't disagree.
            reload()
            present(error, title: String(localized: "Couldn't create the link"))
        }
    }

    // MARK: - Invite link posture (manual close only — invariant 9)

    /// Owner side, once the partner is in and the server says the link is still
    /// open (the cached flag alone goes stale across devices and rejoins).
    var showsCloseLinkPrompt: Bool {
        usesLiveShare && isPaired && role == .owner && snapshot.theirs != nil
            && invitePostureChecked && !inviteClosed
            && !closeLinkPromptDismissed && extraShareMembers == nil
    }

    /// More people on the share than the one partner, or `nil`.
    var extraShareMembers: Int? {
        guard usesLiveShare, isPaired, role == .owner, let count = shareMemberCount, count > 1 else { return nil }
        return count
    }

    /// Demo mode's pairing is fake: the share checks would read (and the close
    /// would act on) whatever real share the signed-in account has.
    private var usesLiveShare: Bool {
        #if DEBUG
        return !DemoMode.isActive
        #else
        return true
        #endif
    }

    func dismissCloseLinkPrompt() {
        store.closeLinkPromptDismissed = true
        closeLinkPromptDismissed = true
    }

    /// The server's view of the link backs Home's close prompt this launch.
    private(set) var invitePostureChecked = false

    /// Counts who is on the share and re-reads whether the link is open.
    /// Throttled from the refresh pass; Settings asks directly. Quiet on
    /// failure — the last answer stands.
    func checkShareMembers(throttled: Bool) async {
        guard usesLiveShare, isPaired, role == .owner else { return }
        if throttled, let last = shareMembersCheckedAt,
           Date().timeIntervalSince(last) < AppConfig.shareMemberCheckInterval { return }
        let changesBefore = inviteChanges
        do {
            let (count, state) = try await withDeadline(AppConfig.publishDeadline) {
                (try await CloudSync.shared.shareMemberCount(), try await CloudSync.shared.inviteState())
            }
            shareMembersCheckedAt = Date()
            shareMemberCount = count
            // A close or reopen landed meanwhile: its answer is newer than ours.
            guard inviteChanges == changesBefore, !isChangingInviteLink else { return }
            switch state {
            case .open:
                setInviteClosed(false)
                invitePostureChecked = true
            case .closed:
                setInviteClosed(true)
                invitePostureChecked = true
            case .missing:
                // No share to close: nothing verified.
                invitePostureChecked = false
            }
        } catch {
            log.error("Couldn't count the share's members: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notifications off

    /// Re-read on every foregrounding: the fix happens in the Settings app.
    func checkNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let current = NotificationsNotice.current(authorization: settings.authorizationStatus,
                                                  banners: settings.alertStyle,
                                                  lockScreen: settings.lockScreenSetting,
                                                  notificationCenter: settings.notificationCenterSetting,
                                                  timeSensitive: settings.timeSensitiveSetting)
        let (shown, dismissed) = NotificationsNotice.reconcile(current: current,
                                                               dismissed: store.notificationsNoticeDismissed)
        if store.notificationsNoticeDismissed != dismissed { store.notificationsNoticeDismissed = dismissed }
        if notificationsNotice != shown { notificationsNotice = shown }
    }

    func dismissNotificationsNotice() {
        store.notificationsNoticeDismissed = notificationsNotice
        notificationsNotice = nil
    }

    // MARK: - Lock-screen widget tip

    var showsWidgetTip: Bool { isPaired && snapshot.theirs != nil && !widgetTipDismissed }

    func dismissWidgetTip() {
        store.widgetTipDismissed = true
        widgetTipDismissed = true
    }

    /// A Lock Screen widget already in place retires the tip for good; a Home
    /// Screen one doesn't — the tip is about the Lock Screen.
    private func checkInstalledWidgets() async {
        guard !widgetTipDismissed else { return }
        // The async form is iOS 18+.
        let onLockScreen = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let accessory: Set<WidgetFamily> = [.accessoryCircular, .accessoryRectangular, .accessoryInline]
                continuation.resume(returning: (try? result.get())?.contains { accessory.contains($0.family) } ?? false)
            }
        }
        if onLockScreen { dismissWidgetTip() }
    }

    /// Reconciles the cached invite link against the server. Quiet on failure —
    /// the cached link still shows, and the next attempt tries again.
    func refreshInviteURL() async {
        guard usesLiveShare else {
            // Demo mode's fake pairing has no share to look at: say so, don't spin.
            inviteLinkUnavailable = inviteURL == nil
            return
        }
        guard role == .owner else { return }
        await checkShareMembers(throttled: false)
        let changesBefore = inviteChanges
        do {
            let state = try await CloudSync.shared.inviteState()
            // A close or reopen landed meanwhile: its answer is newer than ours.
            guard inviteChanges == changesBefore, !isChangingInviteLink else { return }
            switch state {
            case .open(let url):
                setInviteURL(url)
                setInviteClosed(false)
                inviteLinkUnavailable = false
            case .closed(let url):
                // How this device finds out the invite was closed from another.
                // The URL is kept: it re-admits the existing partner on a new
                // phone, and admits nobody else.
                setInviteURL(url)
                setInviteClosed(true)
                inviteLinkUnavailable = false
            case .missing:
                // No link to offer, but nothing says the partner joined — don't claim closed.
                setInviteURL(nil)
                inviteLinkUnavailable = true
            }
        } catch {
            // Couldn't reach iCloud: keep the cached link and stay quiet.
            log.error("Couldn't refresh the invite link: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setInviteClosed(_ closed: Bool) {
        guard inviteClosed != closed else { return }
        inviteClosed = closed
        store.inviteClosed = closed
    }

    private func setInviteURL(_ url: URL?) {
        inviteURL = url
        store.inviteURL = url
    }

    /// An invite close or reopen is in flight. Its own flag, not `isBusy`: a
    /// photo send finishing would clear that one mid-handshake and admit a second close.
    private(set) var isChangingInviteLink = false
    /// Bumped by every close or reopen from here, so a posture check that
    /// started before one can't write its older answer over it.
    @ObservationIgnored private var inviteChanges = 0

    /// Diagnostics' promote-and-close, under the same flag as Settings' so the
    /// two can't race. Returns the report line (`nil`: done or nothing to do).
    func secureInviteFromDiagnostics() async -> String? {
        guard usesLiveShare else { return "Demo mode: the share isn't touched." }
        guard !isChangingInviteLink else { return "A close or reopen is already running." }
        isChangingInviteLink = true
        inviteChanges += 1
        defer { isChangingInviteLink = false; inviteChanges += 1 }
        return await CloudSync.shared.secureInviteIfPartnerJoined()
    }

    /// Settings asks before the re-seat handshake: set when a plain close found
    /// someone on the share (or the partner is known to be in).
    var confirmingInviteReseat = false
    /// Settings' result line after a close or reopen.
    var inviteNotice: String?

    /// Settings' close. With the partner in, closing re-seats them, which only
    /// ever runs after the owner confirms (invariant 9).
    func closeInvite() async {
        guard usesLiveShare, !isChangingInviteLink else { return }
        if snapshot.theirs != nil {
            confirmingInviteReseat = true
            return
        }
        isChangingInviteLink = true
        inviteChanges += 1
        // Bumped again at the end: a check that started mid-change is stale too.
        defer { isChangingInviteLink = false; inviteChanges += 1 }
        do {
            try await CloudSync.shared.closeUnusedInvite()
            // The URL is kept — a closed link still re-admits the existing partner.
            setInviteClosed(true)
        } catch SyncError.inviteInUse {
            confirmingInviteReseat = true
        } catch {
            present(error, title: String(localized: "Couldn't change the invite link"))
        }
    }

    /// The confirmed re-seat: close the link, re-add the partner privately.
    func closeInviteReseatingPartner() async {
        // A second confirmation mid-handshake would race the first's close and re-add.
        guard usesLiveShare, !isChangingInviteLink, let pairing = store.pairing, pairing.role == .owner else { return }
        isChangingInviteLink = true
        inviteChanges += 1
        // Bumped again at the end: a check that started mid-change is stale too.
        defer { isChangingInviteLink = false; inviteChanges += 1 }
        do {
            switch try await CloudSync.shared.lockIfPartnerOnShare(pairing) {
            case .locked:
                inviteNotice = String(localized: "The link is closed. Ask \(partnerName) to tap the invite link once more to get back in.")
            case .nobodyJoined:
                // Nobody *accepted*; a pending private partner survives a close,
                // which `closeUnusedInvite` would refuse. The full lock handles both.
                try await CloudSync.shared.lockPairing()
                inviteNotice = String(localized: "The link is closed.")
            }
        } catch {
            present(error, title: String(localized: "Couldn't change the invite link"))
        }
        reload()
        await refreshInviteURL()
    }

    /// Settings' reopen, behind a confirmation: anyone with the link can join again.
    func reopenInvite() async {
        guard usesLiveShare, !isChangingInviteLink else { return }
        isChangingInviteLink = true
        inviteChanges += 1
        // Bumped again at the end: a check that started mid-change is stale too.
        defer { isChangingInviteLink = false; inviteChanges += 1 }
        do {
            try await CloudSync.shared.reopenInvite()
            inviteNotice = String(localized: "The link is open again. Anyone who has it can join, so send it only to \(partnerName) — if they lost access, they tap it to get back in.")
        } catch {
            present(error, title: String(localized: "Couldn't change the invite link"))
        }
        reload()
        await refreshInviteURL()
    }

    // MARK: - Memories

    /// `0...1` while an archive is being written, `nil` otherwise.
    private(set) var archiveProgress: Double?
    @ObservationIgnored private var archiveTask: Task<MemoryArchive.Outcome?, Never>?
    /// Bumped per archive and by a cancel: a cancelled run winding down in the
    /// background no longer reports progress or offers a share.
    @ObservationIgnored private var archiveRun = 0
    /// The last archive that only reached this device — must be offered for sharing before any delete.
    var archiveToShare: URL?

    /// Paired, the zone may hold more than this phone's capped index, statuses included.
    var hasMemoriesToArchive: Bool { isPaired || !history.isEmpty }
    var canArchiveMemories: Bool { hasMemoriesToArchive && archiveProgress == nil }

    /// Writes the whole zone's history, merged with this phone's, out as plain
    /// files in iCloud Drive. Most media is fetched back from CloudKit (hence
    /// progress), and it must finish *before* anything is deleted. An unreachable
    /// zone still archives this phone's copy; `Outcome.isComplete` says which.
    /// `offeringShare: false` leaves a device-only archive for the caller to
    /// offer: Settings presents `archiveToShare`, and a view pushed over it can't.
    @discardableResult
    func archiveMemories(offeringShare: Bool = true) async -> MemoryArchive.Outcome? {
        archiveRun += 1
        let run = archiveRun
        archiveProgress = 0
        let task = Task { await writeArchive(offeringShare: offeringShare, run: run) }
        archiveTask = task
        let outcome = await task.value
        if archiveRun == run {
            archiveProgress = nil
            archiveTask = nil
        }
        return outcome
    }

    /// Settings' and the fresh start's Cancel: stops the archive, removing what it staged.
    func cancelArchive() {
        archiveTask?.cancel()
        archiveTask = nil
        archiveRun += 1
        archiveProgress = nil
    }

    private func writeArchive(offeringShare: Bool, run: Int) async -> MemoryArchive.Outcome? {
        let backend = self.backend
        var zone: ArchiveContents.Zone?
        do {
            zone = try await withDeadline(AppConfig.refreshDeadline) { try await backend.archiveZone() }
        } catch {
            log.error("Archive couldn't read the zone: \(error.localizedDescription); archiving this iPhone's copy.")
        }
        let contents = ArchiveContents.merged(zone: zone,
                                              localMoments: history,
                                              localStatuses: StatusHistoryLog.shared.load(),
                                              anniversary: snapshot.anniversary,
                                              hidden: store.hiddenMomentIDs)

        do {
            let outcome = try await MemoryArchive.write(contents,
                                                        myName: myDisplayName,
                                                        partnerName: partnerName,
                                                        reportedStatusAt: hiddenPartnerStatusAt) { fraction in
                Task { @MainActor in
                    guard self.archiveRun == run else { return }
                    self.archiveProgress = fraction
                }
            }
            guard archiveRun == run else { return nil }
            if outcome.destination == .deviceOnly, offeringShare {
                // Nothing is safe yet: the folder only exists here until the user saves it somewhere.
                archiveToShare = outcome.folder
            }
            return outcome
        } catch is CancellationError {
            return nil
        } catch {
            guard archiveRun == run else { return nil }
            present(error, title: String(localized: "Couldn't save your memories"))
            return nil
        }
    }

    // MARK: - Fresh start (clear the history, both agreeing)

    /// Where the fresh start stands on this phone — see `FreshStartPolicy.Phase`.
    var freshStartPhase: FreshStartPolicy.Phase {
        guard let role else { return .idle(lastCleared: nil) }
        return FreshStartPolicy.phase(snapshot.freshStart, role: role)
    }

    /// A change of ours is still waiting to reach iCloud.
    var freshStartSending: Bool { snapshot.freshStart.pendingIntent != nil }
    var isClearingHistory: Bool { outbox.isClearingHistory }
    var freshStartFailure: String? { outbox.freshStartFailure }
    /// An ask, agree or withdraw is in flight.
    private(set) var isChangingFreshStart = false

    /// The partner's standing ask, unless its Home card was waved away.
    var showsFreshStartRequest: Bool {
        guard isPaired, case .theyAsked(let asked) = freshStartPhase else { return false }
        return snapshot.freshStart.dismissedAsk != asked
    }

    /// The clear is due here but keeps failing — worth a card of its own.
    var freshStartNeedsAttention: Bool {
        guard isPaired, case .clearing = freshStartPhase else { return false }
        return freshStartFailure != nil && !isClearingHistory
    }

    var partnerFinishedFreshStart: Bool {
        guard let epoch = snapshot.freshStart.finishedBefore else { return false }
        return (snapshot.freshStart.theirs?.clearedBefore ?? .distantPast) >= epoch
    }

    /// Asks for a fresh start. Looks for a standing ask from them first — then
    /// this is theirs to agree to instead. Returns what to tell the user, if anything.
    func askForFreshStart() async -> String? {
        guard isPaired, !isChangingFreshStart else { return nil }
        isChangingFreshStart = true
        defer { isChangingFreshStart = false }
        await refresh()
        switch freshStartPhase {
        case .idle, .waitingForPartner:
            break
        case .theyAsked:
            return String(localized: "\(partnerName) has just asked for a fresh start too — you can agree to theirs instead.")
        default:
            return nil
        }
        do {
            let asked = try await outbox.askForFreshStart()
            reload()
            if !asked {
                return String(localized: "Your last fresh start change is still being sent. Try again in a moment.")
            }
            Task { await advanceFreshStart() }
            return nil
        } catch is CancellationError {
            // Abandoned at the deadline, it may still land: the next refresh reads it back.
            reload()
            return String(localized: "iCloud didn't answer in time. If the request got through, it shows here shortly.")
        } catch {
            reload()
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return String(localized: "Couldn't reach iCloud, so nothing was asked. (\(reason))")
        }
    }

    /// Agrees to the partner's standing ask — final. Re-checked against a fresh
    /// refresh first: agreeing to an ask they've since withdrawn would do nothing.
    func agreeToFreshStart() async -> String? {
        guard isPaired, !isChangingFreshStart else { return nil }
        isChangingFreshStart = true
        defer { isChangingFreshStart = false }
        await refresh()
        guard case .theyAsked(let asked) = freshStartPhase else {
            return String(localized: "\(partnerName) has withdrawn the request, so nothing changes.")
        }
        let result = await outbox.publishFreshStart(.agree(asked))
        reload()
        Task { await advanceFreshStart() }
        if result == nil {
            return String(localized: "Your answer is saved on this iPhone and will be sent once iCloud can be reached.")
        }
        return nil
    }

    /// Takes our ask back, until the partner's phone has committed to it.
    func withdrawFreshStart() async -> String? {
        guard isPaired, !isChangingFreshStart, case .asked = freshStartPhase else { return nil }
        isChangingFreshStart = true
        defer { isChangingFreshStart = false }
        let result = await outbox.publishFreshStart(.withdraw)
        reload()
        switch result {
        case .refused?:
            Task { await advanceFreshStart() }
            return String(localized: "\(partnerName) had already agreed, so the fresh start is going ahead.")
        case nil where freshStartSending:
            return String(localized: "Withdrawn on this iPhone; iCloud will be told once it can be reached.")
        default:
            return nil
        }
    }

    /// The sheet's "Try again", and the start of a clear just agreed.
    func advanceFreshStart() async {
        await outbox.advanceFreshStart()
        reload()
    }

    func dismissFreshStartRequest() {
        guard case .theyAsked(let asked) = freshStartPhase else { return }
        store.mutate(reloadWidgets: false) { $0.freshStart.dismissedAsk = asked }
        reload()
    }

    // MARK: - Ending it

    /// Ends the link, cloud first, then locally. Order matters: if iCloud can't be
    /// cleaned up we keep the pairing and change nothing — a local reset that leaves
    /// photos in someone else's iCloud must not look like it didn't.
    /// - Parameter startingOver: also forgets your name.
    /// - Returns: `false` if nothing was changed.
    @discardableResult
    func unlink(startingOver: Bool) async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            try await backend.unpair()
        } catch {
            present(error, title: String(localized: "Couldn't unlink"))
            return false
        }

        finishUnlink(startingOver: startingOver)
        return true
    }

    /// Cuts this device loose without touching iCloud — for when the delete can't
    /// go through and waiting isn't acceptable. The caller must say what stays behind.
    func forceLocalReset(startingOver: Bool) {
        finishUnlink(startingOver: startingOver)
    }

    private func finishUnlink(startingOver: Bool) {
        // Until both databases confirm, the ex's writes may keep pushing here.
        store.subscriptionCleanup = .init(userRecordName: store.pairing?.userRecordName, since: Date())
        Task { await cleanUpSubscriptionsIfNeeded() }
        store.eraseLocalMedia()
        store.clearPairing(keepingName: !startingOver)
        inviteURL = nil  // `clearPairing` already cleared the stored copy.
        pendingInvite = nil
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Errors

    /// A failed send is filed locally and retried, and Home shows it waiting
    /// (the status row, the footer): no alert. A full iCloud is the exception —
    /// only someone can fix it — once per automatic-retry back-off.
    private func presentSendFailure(_ error: Error, noun: String) {
        let code = (error as? CKError).map { "CKError \($0.code.rawValue): " } ?? ""
        log.error("Send failed (\(code, privacy: .public))\(error.localizedDescription, privacy: .public)")
        let alreadyFull = outbox.storageFullAt
        guard outbox.noteSendFailed(error) == .storageFull else { return }
        if let alreadyFull, Date().timeIntervalSince(alreadyFull) < AppConfig.storageFullRetryInterval { return }
        // Whose storage it is decides who can fix it: the zone lives in the owner's iCloud.
        errorTitle = String(localized: "iCloud is full")
        errorMessage = role == .participant
            ? String(localized: "\(partnerName)'s iCloud storage is full. Your shared space lives in their iCloud, so that \(noun) can't be sent until they free up some space. It's saved on this iPhone and will go then.")
            : String(localized: "Your iCloud storage is full, so that \(noun) can't be sent yet. It's saved on this iPhone and will go once there's space. Your shared space lives in your iCloud, so everything either of you sends counts against it.")
    }

    private func present(_ error: Error, title: String? = nil) {
        // Log the CKError code — the message alone doesn't distinguish transient from real.
        let code = (error as? CKError).map { "CKError \($0.code.rawValue): " } ?? ""
        log.error("\(code, privacy: .public)\(error.localizedDescription, privacy: .public)")
        errorTitle = title
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Notification upkeep

/// Local notification upkeep that follows the model's state: milestone
/// reminders, the unpaired subscription cleanup, the gallery's deferred reload.
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
            try await withDeadline(AppConfig.publishDeadline) {
                try await CloudSync.shared.deleteAllSubscriptions(ownedBy: pending.userRecordName)
            }
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
        let backend = backend
        try? await withDeadline(AppConfig.publishDeadline) { try await backend.registerSubscription() }
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
