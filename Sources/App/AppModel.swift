import CloudKit
import Foundation
import Network
import Observation
import SwiftUI
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

    var errorMessage: String?
    /// Informational, not a failure — shown under its own title (see `RootView`).
    var noticeMessage: String?
    /// Set by the `redstring://compose` deep link so the widget opens straight into the composer.
    var pendingComposer = false

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
    /// `createInvite` found this account's old space still has someone in it;
    /// the pairing screen asks before deleting it (`createInvite(replacingExisting:)`).
    var confirmingReplacePairing = false

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
                             backend: backendProvider,
                             hasMedia: { MomentStore.shared.hasMedia(for: $0) },
                             protect: { name, body in try await AppModel.withUploadProtection(name, body) },
                             indexChanged: { store.refreshDerived() })
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
    }

    // MARK: - Derived

    /// The partner's name as shown everywhere — filtered like any of their text.
    var partnerName: String { snapshot.moderatedPartnerName }

    /// When the two of them began, as the owner set it — `nil` until they do.
    var anniversary: Anniversary? { snapshot.anniversary }
    /// Only the zone owner sets the date; the participant just receives it.
    var canEditAnniversary: Bool { isPaired && role == .owner }

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
        history.first { !$0.fromMe && !$0.isVoice }
    }

    /// Partner's unviewed pictures, newest first — the same order the home card previews.
    var unseenVisualMoments: [Moment] {
        history.filter { !$0.fromMe && !$0.seen && !$0.isVoice }
    }

    /// The last memo the partner sent, heard or not — kept playable on the home screen.
    var latestReceivedVoiceMemo: Moment? {
        history.first { !$0.fromMe && $0.isVoice }
    }

    /// Own moments not yet in CloudKit — the sync footer count and the outbox's retry set.
    var pendingUploadCount: Int {
        history.count { $0.fromMe && !$0.uploaded }
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
    func markSeen(_ moment: Moment) {
        guard !moment.seen, !moment.fromMe else { return }
        history = MomentIndex.shared.markSeen(ids: [moment.id])
        // The widget's unheard-memo badge is a snapshot field; this is what clears it.
        store.refreshDerived()
        snapshot = store.snapshot
        if readReceiptsEnabled, isPaired {
            store.mutate(reloadWidgets: false) { $0.receiptsDirty = true }
            Task { await flushReceiptsIfNeeded() }
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
            present(error)
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
            present(error)
        }
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        startNetworkMonitoring()
        // Cold-start link taps land here: the scene delegate ran before any view could listen.
        if let invite = InviteInbox.shared.take() {
            receiveInvite(invite)
        }
        await refreshReadiness()
        guard isPaired else { return }
        // One receipt publish per launch even when nothing marked itself dirty:
        // covers moments seen before receipts existed and heals lost publishes —
        // with receipts off too, so a retraction a stale write overtook is re-sent.
        store.mutate(reloadWidgets: false) { $0.receiptsDirty = true }
        // Subscriptions are cheap to re-assert and easy to lose across reinstalls.
        let backend = backend
        try? await withDeadline(AppConfig.publishDeadline) { try await backend.registerSubscription() }
        await refresh()
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
        history = MomentIndex.shared.load()
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
            errorMessage = String(localized: "\(name) is blocked and everything they sent has been removed from this iPhone. iCloud couldn't be reached to finish the unlink (\(cloudProblem)), so what you sent may still be in the shared space; try Settings → Unlink later if it reappears.")
        }
    }

    /// Opens Mail with the report. Without a mail account the text goes to the
    /// clipboard instead, with the address to send it to.
    private func sendReport(_ details: Report.Details) {
        let body = Report.body(for: details)
        guard let url = Report.mailURL(for: details) else { return }
        UIApplication.shared.open(url) { opened in
            guard !opened else { return }
            Task { @MainActor in
                UIPasteboard.general.string = body
                self.noticeMessage = String(localized: "Mail isn't set up on this iPhone, so the report has been copied to your clipboard. Please email it to \(AppConfig.supportEmail).")
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
    /// as the tile scrolls into view. `false` when it still isn't on disk.
    func ensureThumbnail(for moment: Moment) async -> Bool {
        if MomentStore.shared.hasThumbnail(for: moment.id) { return true }
        do {
            // Bounded: the recovery pass awaits this, and a stall would hold it.
            let backend = backend
            try await withDeadline(AppConfig.publishDeadline) { try await backend.fetchThumbnail(for: moment) }
            return MomentStore.shared.hasThumbnail(for: moment.id)
        } catch {
            log.error("Couldn't fetch thumbnail for \(moment.id): \(error.localizedDescription)")
            return false
        }
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
    }

    /// Refreshes only on the offline→online edge — `refresh()` already handles
    /// offline calls and re-entrancy; the job here is ignoring path churn while up.
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBackOnline = satisfied && !self.networkWasSatisfied
                self.networkWasSatisfied = satisfied
                if cameBackOnline {
                    self.log.notice("Network is back; refreshing.")
                    await self.refresh()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "redstring.network-path"))
    }

    /// The system reported an iCloud account change: make the next readiness
    /// check look the account up for real, then refresh.
    func accountDidChange() async {
        await backend.noteAccountChanged()
        await refresh()
    }

    /// Returns once the fetch lands; the recovery pass it unlocks runs on after,
    /// so pull-to-refresh doesn't wait on uploads.
    func refresh() async {
        guard refreshGate.begin() else { return }
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
            if await outbox.republishStatus() { reload() }
            if await outbox.republishAnniversary() { reload() }
            if await outbox.republishAnniversaryRequest() { reload() }
            // Re-read at once: the footer and the tiles' clocks read `history`.
            if await outbox.retryPendingUploads(automatic: true) { reload() }
            await outbox.flushReceipts()
            await restoreLatestThumbnailIfMissing()
            await checkShareMembers(throttled: true)
            await checkInstalledWidgets()
        } while recoveryGate.takeRequest()
        recoveryGate.end()
    }

    /// One fetch and reload; `false` when it failed or there was nothing to fetch for.
    private func fetchOnce() async -> Bool {
        // Re-checked when paired too: this is what notices an iCloud account switch.
        await refreshReadiness()
        guard isPaired else { return false }
        do {
            try await SyncRunner.refresh()
            reload()
            return true
        } catch {
            // The backend may have unlinked us (a vanished zone means the other
            // person ended things), so re-read local state either way.
            reload()
            if let sync = error as? SyncError, case .linkEnded = sync {
                // The one refresh failure that is really a message from another person.
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
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
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
        let paired = isPaired
        store.mutate {
            $0.mine = payload
            $0.myStatusPublished = !paired
        }
        StatusHistoryLog.shared.record(payload, fromMe: true)
        reload()

        guard paired else { return }
        do {
            let backend = backend
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publish(payload) }
            store.mutate(reloadWidgets: false) { $0.markStatusPublished(payload) }
            outbox.noteSendSucceeded()
            reload()
        } catch {
            presentSendFailure(error, noun: String(localized: "status update"))
        }
    }

    private func updateMyDisplayName(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = snapshot.mine ?? .initial(displayName: trimmed)
        payload.displayName = trimmed
        // The words keep their own date; only the record's stamp moves.
        payload.wordsSince = payload.wordsAt
        // Fresh stamp: the resync revert-guard orders by `updatedAt`, and a stale one would lose.
        payload.updatedAt = statusTimestamp()
        let paired = isPaired
        store.mutate {
            $0.mine = payload
            $0.myStatusPublished = !paired
        }
        reload()

        guard paired else { return }
        // Not logged: the status didn't change, only the name on it — unless the
        // status itself never made it into the log (set offline, then renamed).
        let logged = store.snapshot.myStatusLoggedAt != payload.wordsAt
        let backend = backend
        Task { [payload] in
            do {
                try await withDeadline(AppConfig.publishDeadline) { try await backend.publish(payload, logged: logged) }
                store.mutate(reloadWidgets: false) { $0.markStatusPublished(payload) }
            } catch {
                // Quiet: the name is right locally, and the outbox's republish carries it over.
                outbox.noteSendFailed(error)
                log.error("Name publish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Nudge

    func sendNudge() async {
        guard canNudge else { return }
        do {
            if try await backend.sendNudge() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            reload()
        } catch {
            present(error)
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
            present(error)
            return
        }

        store.record(moment)
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard isPaired else { return }
        do {
            let backend = backend
            try await Self.withUploadProtection("moment-upload") {
                try await withDeadline(AppConfig.uploadDeadline) { try await backend.send(moment) }
                markUploaded(moment)
            }
            outbox.noteSendSucceeded()
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
            present(error)
            return
        }

        store.record(moment)
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard isPaired else { return }
        do {
            let backend = backend
            try await Self.withUploadProtection("voice-memo-upload") {
                try await withDeadline(AppConfig.uploadDeadline) { try await backend.send(moment) }
                markUploaded(moment)
            }
            outbox.noteSendSucceeded()
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
        for key in ["private", "shared"] { store.setChangeToken(nil, for: key) }
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

    /// Flips the pending flag once the record is confirmed on the server.
    private func markUploaded(_ moment: Moment) {
        history = MomentIndex.shared.markUploaded(ids: [moment.id])
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

    /// The home footer's tap-to-retry: the same pass the next refresh would
    /// run, without waiting for one. The outbox guards re-entry.
    func retryPendingNow() async {
        await outbox.retryPendingUploads(automatic: false)
        reload()
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
        var changed = false
        store.mutate(reloadWidgets: false) { changed = $0.stampPartnerStatusSeen(shown, at: Date()) }
        guard changed else { return }
        snapshot = store.snapshot
        Task { await flushReceiptsIfNeeded() }
    }

    /// Publishes this device's receipts when they're dirty; the outbox claims
    /// the flag before the network call and re-sets it on failure.
    func flushReceiptsIfNeeded() async {
        await outbox.flushReceipts()
    }

    // MARK: - Status history

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
            present(error)
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
            present(error)
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
            present(error)
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
            present(error)
        }
        reload()
        await refreshInviteURL()
    }

    // MARK: - Memories

    /// `0...1` while an archive is being written, `nil` otherwise.
    private(set) var archiveProgress: Double?
    /// The last archive that only reached this device — must be offered for sharing before any delete.
    var archiveToShare: URL?

    var canArchiveMemories: Bool { !history.isEmpty && archiveProgress == nil }

    /// Writes the history out as plain files in iCloud Drive. Most media is fetched
    /// back from CloudKit (hence progress), and it must finish *before* anything is deleted.
    @discardableResult
    func archiveMemories() async -> MemoryArchive.Outcome? {
        guard !history.isEmpty else { return nil }
        archiveProgress = 0
        defer { archiveProgress = nil }

        do {
            let outcome = try await MemoryArchive.write(history,
                                                        partnerName: partnerName) { fraction in
                Task { @MainActor in self.archiveProgress = fraction }
            }
            if outcome.destination == .deviceOnly {
                // Nothing is safe yet: the folder only exists here until the user saves it somewhere.
                archiveToShare = outcome.folder
            }
            return outcome
        } catch {
            present(error)
            return nil
        }
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
            present(error)
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
        store.eraseLocalMedia()
        store.clearPairing(keepingName: !startingOver)
        inviteURL = nil  // `clearPairing` already cleared the stored copy.
        pendingInvite = nil
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Errors

    /// A failed upload is filed locally and retried, so the alert says that
    /// instead of reading like the send is gone.
    private func presentSendFailure(_ error: Error, noun: String) {
        let code = (error as? CKError).map { "CKError \($0.code.rawValue): " } ?? ""
        log.error("Send failed (\(code, privacy: .public))\(error.localizedDescription, privacy: .public)")
        switch outbox.noteSendFailed(error) {
        case .storageFull:
            // Whose storage it is decides who can fix it: the zone lives in the owner's iCloud.
            errorMessage = role == .participant
                ? String(localized: "\(partnerName)'s iCloud storage is full. Your shared space lives in their iCloud, so that \(noun) can't be sent until they free up some space. It's saved on this iPhone and will go then.")
                : String(localized: "Your iCloud storage is full, so that \(noun) can't be sent yet. It's saved on this iPhone and will go once there's space. Your shared space lives in your iCloud, so everything either of you sends counts against it.")
        case .transient:
            errorMessage = String(localized: "Couldn't send that \(noun) right now — it's saved, and will be sent automatically next time you open the app.")
        }
    }

    private func present(_ error: Error) {
        // Log the CKError code — the message alone doesn't distinguish transient from real.
        let code = (error as? CKError).map { "CKError \($0.code.rawValue): " } ?? ""
        log.error("\(code, privacy: .public)\(error.localizedDescription, privacy: .public)")
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
