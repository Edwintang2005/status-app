import CloudKit
import Foundation
import Network
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class AppModel {
    private let store: SharedStore
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "AppModel")

    private(set) var snapshot: Snapshot
    private(set) var isPaired: Bool
    private(set) var role: PairRole?
    /// Owner side: invite revoked, via Settings or automatically once the partner joined.
    private(set) var inviteClosed: Bool = SharedStore.shared.inviteClosed
    private(set) var isBusy = false
    private(set) var isRefreshing = false
    /// Re-entrancy guard: a slow retry must not overlap the next foreground's.
    @ObservationIgnored private var isRetryingUploads = false
    @ObservationIgnored private var isRepublishingStatus = false

    /// Fires a refresh on the offline→online edge — the only trigger that watches the network itself.
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Starts `true` so the monitor's immediate first callback doesn't double up with `onLaunch`'s refresh.
    @ObservationIgnored private var networkWasSatisfied = true
    /// Owner side: the link to hand to the partner, `nil` once closed.
    /// Seeded from the store so it survives a relaunch — see `refreshInviteURL()`.
    private(set) var inviteURL: URL? = SharedStore.shared.inviteURL
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
    /// Set by the `redstring://compose` deep link so the widget opens straight into the composer.
    var pendingComposer = false

    /// A tapped invite held until `WelcomeView` has a display name — see `acceptInvite(name:)`.
    private(set) var pendingInvite: CKShare.Metadata?

    /// Store is injectable so previews and tests run against a throwaway defaults suite.
    init(store: SharedStore = .shared) {
        self.store = store
        self.snapshot = store.snapshot
        self.isPaired = store.pairing != nil
        self.role = store.pairing?.role
    }

    // MARK: - Derived

    var partnerName: String { snapshot.partnerDisplayName }

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

    /// Own moments not yet in CloudKit — the sync footer count and `retryPendingUploads()` set.
    var pendingUploadCount: Int {
        history.count { $0.fromMe && !$0.uploaded }
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
        store.applyDerived(from: history)
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
            errorMessage = "You're already linked with \(partnerName). "
                + "To join a new invite, unlink first in Settings."
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

    // MARK: - Lifecycle

    func onLaunch() async {
        startNetworkMonitoring()
        // Cold-start link taps land here: the scene delegate ran before any view could listen.
        if let invite = InviteInbox.shared.take() {
            receiveInvite(invite)
        }
        await refreshReadiness()
        guard isPaired else { return }
        // Subscriptions are cheap to re-assert and easy to lose across reinstalls.
        try? await Backend.current.registerSubscription()
        await refresh()
    }

    /// Called when the scene delegate has accepted an invite.
    func reloadFromStore() async {
        reload()
        // First moment the notification prompt makes sense — a nudge is now receivable.
        await NotificationManager.requestAuthorizationIfNeeded()
        await refresh()
    }

    private func reload() {
        snapshot = store.snapshot
        isPaired = store.pairing != nil
        role = store.pairing?.role
        inviteClosed = store.inviteClosed
        // The invite can close itself (CloudSync, on partner join); drop the dead link.
        if inviteClosed, inviteURL != nil { setInviteURL(nil) }
        history = MomentIndex.shared.load()
    }

    /// Older entries keep metadata but not media files; fetches the file back from CloudKit on demand.
    func ensureMedia(for moment: Moment) async -> Bool {
        if MomentStore.shared.hasMedia(for: moment) { return true }
        do {
            try await Backend.current.fetchMedia(for: moment)
            return MomentStore.shared.hasMedia(for: moment)
        } catch {
            log.error("Couldn't fetch media for \(moment.id): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Sync

    /// PairingView's iCloud warning. Re-checked on every foregrounding, not just
    /// launch — the fix happens in the Settings app, so the user returns expecting it noticed.
    private func refreshReadiness() async {
        if case .unavailable(let message) = await Backend.current.readiness() {
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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Re-checked when paired too: this is what notices an iCloud account switch.
        await refreshReadiness()
        guard isPaired else { return }
        do {
            try await SyncRunner.refresh()
            reload()
            // A working refresh is the recovery moment for sends that died offline.
            await republishStatusIfNeeded()
            await retryPendingUploads()
            await flushReceiptsIfNeeded()
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
        }
    }

    // MARK: - Status

    func setStatus(emoji: String, message: String, isCelebration: Bool = false) async {
        let payload = StatusPayload(
            emoji: emoji,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: snapshot.mine?.displayName ?? "",
            updatedAt: Date(),
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
            try await Backend.current.publish(payload)
            markStatusPublished(payload)
            reload()
        } catch {
            presentSendFailure(error, noun: "status update")
        }
    }

    /// Flips the published flag only if `payload` is still the current status —
    /// a late-finishing publish must not mark a newer offline edit as delivered.
    private func markStatusPublished(_ payload: StatusPayload) {
        store.mutate(reloadWidgets: false) {
            guard $0.mine?.updatedAt == payload.updatedAt else { return }
            $0.myStatusPublished = true
        }
    }

    private func updateMyDisplayName(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = snapshot.mine ?? .initial(displayName: trimmed)
        payload.displayName = trimmed
        // Fresh stamp: the resync revert-guard orders by `updatedAt`, and a stale one would lose.
        payload.updatedAt = Date()
        let paired = isPaired
        store.mutate {
            $0.mine = payload
            $0.myStatusPublished = !paired
        }
        reload()

        guard paired else { return }
        Task { [payload] in
            do {
                try await Backend.current.publish(payload)
                markStatusPublished(payload)
            } catch {
                // Quiet: the name is right locally, and `republishStatusIfNeeded` carries it over.
                log.error("Name publish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Nudge

    func sendNudge() async {
        guard canNudge else { return }
        do {
            if try await Backend.current.sendNudge() {
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
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
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
            try await withUploadProtection("moment-upload") {
                try await Backend.current.send(moment)
            }
            markUploaded(moment)
        } catch {
            presentSendFailure(error, noun: moment.noun)
        }
    }

    /// Runs an upload inside a background-task assertion so locking the phone
    /// doesn't suspend the process mid-upload and silently lose the send.
    private func withUploadProtection<T>(_ name: String,
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
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
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
            try await withUploadProtection("voice-memo-upload") {
                try await Backend.current.send(moment)
            }
            markUploaded(moment)
        } catch {
            presentSendFailure(error, noun: moment.noun)
        }
    }

    /// Flips the pending flag once the record is confirmed on the server.
    private func markUploaded(_ moment: Moment) {
        history = MomentIndex.shared.markUploaded(ids: [moment.id])
    }

    /// Re-publishes the local status if its last publish never landed; runs on every
    /// successful refresh, quiet on failure (the send path already alerted once).
    /// Safe to re-run: `publish` overwrites a fixed record name, and only this device writes it.
    func republishStatusIfNeeded() async {
        guard isPaired, !isRepublishingStatus else { return }
        let snapshot = store.snapshot
        guard !snapshot.myStatusPublished, let mine = snapshot.mine else { return }
        isRepublishingStatus = true
        defer { isRepublishingStatus = false }

        do {
            try await Backend.current.publish(mine)
            markStatusPublished(mine)
            reload()
            log.info("Republished the offline status update")
        } catch {
            log.error("Status republish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-sends own moments whose upload never completed; runs on every foreground
    /// refresh, quiet on failure (the pending badge already says so).
    /// Safe to re-run — `CloudSync.send` overwrites a deterministic record name.
    func retryPendingUploads() async {
        guard isPaired, !isRetryingUploads else { return }
        let pending = history.filter { $0.fromMe && !$0.uploaded }
        guard !pending.isEmpty else { return }
        isRetryingUploads = true
        defer { isRetryingUploads = false }

        for moment in pending {
            // Pruned/wiped media can never be delivered; drop the ghost entry
            // rather than retrying forever or falsely marking it uploaded.
            guard MomentStore.shared.hasMedia(for: moment) else {
                log.error("Dropping pending moment \(moment.id, privacy: .public): its media is gone.")
                MomentIndex.shared.remove(id: moment.id)
                history = MomentIndex.shared.load()
                store.applyDerived(from: history)
                continue
            }
            do {
                try await withUploadProtection("moment-retry") {
                    try await Backend.current.send(moment)
                }
                markUploaded(moment)
                log.info("Retried upload of \(moment.id, privacy: .public) successfully")
            } catch {
                log.error("Retry upload of \(moment.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Read receipts

    /// Whether this device shares (and shows) read receipts. Off by default;
    /// each side controls its own sending, and display is gated on the same switch.
    var readReceiptsEnabled: Bool = SharedStore.shared.readReceiptsEnabled {
        didSet {
            guard oldValue != readReceiptsEnabled else { return }
            store.readReceiptsEnabled = readReceiptsEnabled
            // Publish the backlog when enabling; retract with an empty map when disabling.
            store.mutate(reloadWidgets: false) { $0.receiptsDirty = true }
            Task { await flushReceiptsIfNeeded() }
        }
    }

    @ObservationIgnored private var isFlushingReceipts = false

    /// Seen-state of the partner's moments, newest first, capped. `.distantPast`
    /// marks entries seen before per-moment timestamps existed ("seen", no time).
    private func currentSeenMap() -> [String: Date] {
        var map: [String: Date] = [:]
        for moment in history where !moment.fromMe && moment.seen {
            map[moment.id] = moment.seenAt ?? .distantPast
            if map.count >= AppConfig.receiptMapLimit { break }
        }
        return map
    }

    /// Publishes this device's seen-map when it has changed. Quiet on failure —
    /// the dirty flag stays set, so the next refresh retries.
    func flushReceiptsIfNeeded() async {
        guard isPaired, !isFlushingReceipts, store.snapshot.receiptsDirty else { return }
        isFlushingReceipts = true
        defer { isFlushingReceipts = false }
        let map = readReceiptsEnabled ? currentSeenMap() : [:]
        do {
            try await Backend.current.publishReceipts(map)
            store.mutate(reloadWidgets: false) { $0.receiptsDirty = false }
        } catch {
            log.error("Receipt publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Status history

    /// The rolling status log, newest first — loaded on demand by the history sheet.
    func loadStatusHistory() -> [StatusHistoryEntry] {
        StatusHistoryLog.shared.load()
    }

    // MARK: - Pairing

    func createInvite() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await CloudSync.shared.createPairInvite(displayName: myDisplayName)
            setInviteURL(url)
            reload()
            // After `reload()`, which flips `isPaired` and dismisses the pairing screen.
            presentedInvite = InviteLink(url: url)
            await NotificationManager.requestAuthorizationIfNeeded()
        } catch {
            // `createPairInvite` commits the pairing before its bootstrap publish;
            // reload so the store and this model can't disagree.
            reload()
            present(error)
        }
    }

    /// Reconciles the cached invite link against the server. Quiet on failure —
    /// the cached link still shows, and the next attempt tries again.
    func refreshInviteURL() async {
        guard role == .owner else { return }
        do {
            switch try await CloudSync.shared.inviteState() {
            case .open(let url):
                setInviteURL(url)
                setInviteClosed(false)
                inviteLinkUnavailable = false
            case .closed:
                // How this device finds out the invite was closed from another.
                setInviteURL(nil)
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

    func lockPairing() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await CloudSync.shared.lockPairing()
            setInviteURL(nil)
            // Without this the invite section shows an unresolving spinner instead of "Closed".
            setInviteClosed(true)
        } catch {
            present(error)
        }
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
            try await Backend.current.unpair()
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
        errorMessage = "Couldn't send that \(noun) right now — it's saved, and will be sent automatically next time you open the app."
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
