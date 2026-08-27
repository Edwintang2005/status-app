import CloudKit
import Foundation
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
    /// Owner side: whether the invite link has been revoked, either by the
    /// button in Settings or automatically once the partner joined.
    private(set) var inviteClosed: Bool = SharedStore.shared.inviteClosed
    private(set) var isBusy = false
    private(set) var isRefreshing = false
    /// Owner side: the link to hand to the partner, `nil` once it has been
    /// closed. Seeded from the store rather than left empty, so it survives a
    /// relaunch — see `refreshInviteURL()`.
    private(set) var inviteURL: URL? = SharedStore.shared.inviteURL
    /// The server has no share for us at all — as opposed to one that has been
    /// closed. Keeps Settings from spinning forever on a link that is never
    /// going to arrive.
    private(set) var inviteLinkUnavailable = false
    /// Non-nil when the backend can't work — no iCloud account, and so on.
    private(set) var readinessMessage: String?
    /// The full moment history, newest first. Read from `MomentIndex` rather
    /// than the snapshot, which only carries the newest in each direction.
    private(set) var history: [Moment] = []

    /// Set when an invite has just been created, so `RootView` can present the
    /// link. Not a plain `URL`: `sheet(item:)` needs identity, and the same
    /// link created twice should still present.
    var presentedInvite: InviteLink?

    /// A link to show, wrapped so SwiftUI can key a sheet on it.
    struct InviteLink: Identifiable {
        let id = UUID()
        let url: URL
    }

    var errorMessage: String?
    /// Set by the `redstring://compose` deep link so the widget can open straight
    /// into the composer.
    var pendingComposer = false

    /// An invite link that has been tapped but not yet accepted, because the
    /// person tapping it hasn't told us what to call them.
    ///
    /// Accepting a share used to happen the instant the link opened the app,
    /// which meant a brand-new install joined under whatever the *device* was
    /// called. The metadata is held here instead until `WelcomeView` has a
    /// name — see `acceptInvite(name:)`.
    private(set) var pendingInvite: CKShare.Metadata?

    /// The store is injectable so SwiftUI previews and tests can run against a
    /// throwaway defaults suite instead of the real App Group.
    init(store: SharedStore = .shared) {
        self.store = store
        self.snapshot = store.snapshot
        self.isPaired = store.pairing != nil
        self.role = store.pairing?.role
    }

    // MARK: - Derived

    var partnerName: String { snapshot.partnerDisplayName }

    /// Whether this person has ever told us their name. The one gate in front
    /// of the rest of the app: a status, a nudge and every photo carry this
    /// name to the other phone, so there is no sensible default to invent.
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

    /// The newest photo or doodle *the partner sent* — what the home card
    /// shows. Not either direction: this card is "what did they send me", and
    /// your own send replacing their picture the moment you reply defeats it
    /// (your own things live in the library). Voice memos are deliberately
    /// excluded: they get their own short row, because a waveform stretched
    /// into a square photo frame is mostly empty space.
    var latestVisualMoment: Moment? {
        history.first { !$0.fromMe && !$0.isVoice }
    }

    /// Pictures the partner sent that haven't been looked at yet, newest first
    /// — the same order the home card previews, so tapping it opens the one you
    /// were just looking at rather than jumping to the oldest.
    var unseenVisualMoments: [Moment] {
        history.filter { !$0.fromMe && !$0.seen && !$0.isVoice }
    }

    /// The last memo the partner sent, heard or not — the one the home screen
    /// keeps a row for, so it stays playable rather than disappearing the
    /// moment it's been listened to once. Everything older is in the history.
    var latestReceivedVoiceMemo: Moment? {
        history.first { !$0.fromMe && $0.isVoice }
    }

    /// What tapping the home card opens: whatever is waiting, or — when you're
    /// caught up — just the most recent thing, rather than the entire archive.
    var carouselMoments: [Moment] {
        let unseen = unseenVisualMoments
        if !unseen.isEmpty { return unseen }
        return [latestVisualMoment].compactMap { $0 }
    }

    /// Looked at, or — for a memo — listened to.
    func markSeen(_ moment: Moment) {
        guard !moment.seen, !moment.fromMe else { return }
        history = MomentIndex.shared.markSeen(ids: [moment.id])
        // Recomputed rather than left alone: the widget's unheard-memo badge is
        // a snapshot field, and this is what clears it.
        store.applyDerived(from: history)
        snapshot = store.snapshot
    }

    // MARK: - Celebrations

    /// The celebration waiting to be played, if any. Deliberately derived from
    /// the snapshot rather than latched into its own state: every path that
    /// could deliver one — a cold launch reading what the notification
    /// extension already wrote, a foreground refresh, a push — ends in
    /// `reload()`, so there is nothing extra to remember to set.
    var pendingCelebration: StatusPayload? { snapshot.pendingCelebration }

    /// Called once the animation has been watched. Stamping the status's own
    /// `updatedAt` — rather than "now" — is what makes this idempotent: a
    /// re-fetch of the same record can't bring the greeting back, while a
    /// genuinely new celebration always has a later timestamp.
    func celebrationPlayed() {
        guard let celebration = snapshot.pendingCelebration else { return }
        store.mutate { $0.lastCelebratedAt = celebration.updatedAt }
        reload()
    }

    // MARK: - Onboarding

    /// Records the name from the welcome screen. Publishing is left to the
    /// pairing step that follows — there is no zone to write to yet.
    func setName(_ name: String) {
        updateMyDisplayName(name)
    }

    /// Whoever sent the invite, if CloudKit will tell us. It only does when
    /// they're discoverable by their Apple Account, so the joining screen has
    /// to read well without it.
    var pendingInviteOwnerName: String? {
        guard let components = pendingInvite?.ownerIdentity.nameComponents else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .short)
        return name.isEmpty ? nil : name
    }

    /// Called when a share link opens the app. Held rather than accepted, so
    /// the welcome screen can ask for a name first.
    ///
    /// Refused outright while paired: joining a second zone on top of an
    /// existing pairing would leave the old change tokens pointed at the new
    /// zone (killing sync) and the previous relationship's photos and memos
    /// sitting inside the new pairing's gallery. Unlinking first is the only
    /// clean path, and it's one switch away in Settings.
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
            // Kept, not cleared: the link is still the way in, and clearing it
            // would drop the person on the pairing screen with no explanation.
            //
            // Reload first: `acceptShare` commits the pairing before its
            // bootstrap publish, so a failure after that point leaves the
            // store paired while this model still says not — the same window
            // `createInvite` closes the same way.
            reload()
            present(error)
        }
    }

    /// Backing out of a join — the invite is dropped and the normal pairing
    /// screen takes over.
    func declineInvite() {
        pendingInvite = nil
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        // A link tapped from a cold start lands here: the scene delegate ran
        // before any view could hear the notification.
        if let invite = InviteInbox.shared.take() {
            receiveInvite(invite)
        }
        await refreshReadiness()
        guard isPaired else { return }
        // Subscriptions are cheap to re-assert and easy to lose across
        // reinstalls, so confirm on every launch rather than only at pairing.
        try? await Backend.current.registerSubscription()
        await refresh()
    }

    /// Called when the scene delegate has accepted an invite.
    func reloadFromStore() async {
        reload()
        // Only now is a nudge something the user can actually receive, so this
        // is the first moment the notification prompt makes sense to them.
        await NotificationManager.requestAuthorizationIfNeeded()
        await refresh()
    }

    private func reload() {
        snapshot = store.snapshot
        isPaired = store.pairing != nil
        role = store.pairing?.role
        inviteClosed = store.inviteClosed
        // The invite can close itself, from `CloudSync` the moment the partner
        // joins. Dropping the link here keeps Settings from offering one that
        // no longer works.
        if inviteClosed, inviteURL != nil { setInviteURL(nil) }
        history = MomentIndex.shared.load()
    }

    /// Older history entries keep their metadata but not their media files.
    /// The gallery calls this when it reaches one, and CloudKit hands the
    /// photo or recording back — which is the whole point of keeping every
    /// moment as its own record.
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

    /// PairingView's iCloud warning reads this. Re-checked on every
    /// foregrounding (via `refresh`), not just at launch — the fix for the
    /// warning is made in the Settings app, so the user *always* comes back
    /// to a backgrounded app expecting it to notice.
    private func refreshReadiness() async {
        if case .unavailable(let message) = await Backend.current.readiness() {
            readinessMessage = message
        } else {
            readinessMessage = nil
        }
    }

    func refresh() async {
        // Re-checked when paired too: this is what notices an iCloud account
        // switch (readiness compares the signed-in account against the one
        // the pairing was made under) and surfaces it in the sync footer.
        await refreshReadiness()
        guard isPaired else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await SyncRunner.refresh()
            reload()
        } catch {
            // The backend may have unlinked us on its own — a zone that no
            // longer exists is the other person having ended things — so the
            // local state is re-read either way.
            reload()
            if let sync = error as? SyncError, case .linkEnded = sync {
                // Worth interrupting for: this is the one refresh failure that
                // is really a message from another person.
                errorMessage = sync.errorDescription
            }
            // Otherwise background refreshes fail routinely (no signal, iCloud
            // hiccup). The "Synced …" footer already shows staleness, so don't
            // throw a modal alert over a screen the user didn't ask to refresh.
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

        // Show it immediately; the backend catches up underneath.
        store.mutate { $0.mine = payload }
        reload()

        guard isPaired else { return }
        do {
            try await Backend.current.publish(payload)
            reload()
        } catch {
            present(error)
        }
    }

    private func updateMyDisplayName(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = snapshot.mine ?? .initial(displayName: trimmed)
        payload.displayName = trimmed
        store.mutate { $0.mine = payload }
        reload()

        guard isPaired else { return }
        Task { [payload] in
            do { try await Backend.current.publish(payload) } catch { present(error) }
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

        // `senderName` is what the recipient will see, so it has to be the
        // name you set for yourself — captured at send time, which is why an
        // older moment keeps the name you had when you sent it.
        let moment = Moment(
            kind: kind,
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            senderName: snapshot.mine?.displayName ?? "",
            fromMe: true
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
        } catch {
            present(error)
        }
    }

    /// Runs an upload inside a background-task assertion, so sending and
    /// immediately locking the phone doesn't suspend the process mid-upload —
    /// which silently lost the send with no error and no retry.
    private func withUploadProtection<T>(_ name: String,
                                         _ body: () async throws -> T) async rethrows -> T {
        let assertion = BackgroundAssertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            assertion.end()
        }
        defer { assertion.end() }
        return try await body()
    }

    /// Same shape as `sendMoment(image:kind:caption:)`: the recording is filed
    /// locally first so the history and widget are right immediately, then
    /// uploaded. A failed upload leaves the memo playable on this device.
    ///
    /// `fileURL` is the recorder's temporary file and is **moved**, not copied,
    /// so the caller must not use it afterwards.
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
        } catch {
            present(error)
        }
    }

    // MARK: - Pairing

    func createInvite() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await CloudSync.shared.createPairInvite(displayName: myDisplayName)
            setInviteURL(url)
            reload()
            // After `reload()`, which is what flips `isPaired` and takes the
            // pairing screen away. The sheet outlives that.
            presentedInvite = InviteLink(url: url)
            await NotificationManager.requestAuthorizationIfNeeded()
        } catch {
            // `createPairInvite` commits the pairing to the store before its
            // bootstrap publish; if the failure came after that point, the
            // store says paired while this model still says not. Reload so
            // the two can't disagree — the UI follows whichever state is real.
            reload()
            present(error)
        }
    }

    /// Reconciles the cached invite link against what the server actually
    /// says, and records which of the three answers came back.
    ///
    /// Quiet on purpose: this runs when a screen that can show the link
    /// appears, and failing to reach iCloud there is not worth an alert — the
    /// cached link is still shown, and the next attempt tries again.
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
                // There is no link to offer, but nothing here says the partner
                // joined — so don't let the UI claim the invite was closed.
                setInviteURL(nil)
                inviteLinkUnavailable = true
            }
        } catch {
            // Couldn't reach iCloud. Keep the cached link rather than
            // discarding one that very likely still works, and stay quiet.
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
            // Without this the model's copy stays false and the invite
            // section falls into its "loading" branch — a spinner that never
            // resolves — instead of showing "Closed".
            setInviteClosed(true)
        } catch {
            present(error)
        }
    }

    // MARK: - Memories

    /// `0...1` while an archive is being written, `nil` otherwise.
    private(set) var archiveProgress: Double?
    /// The last archive that only made it as far as this device — the caller
    /// has to offer to share it before anything gets deleted.
    var archiveToShare: URL?

    var canArchiveMemories: Bool { !history.isEmpty && archiveProgress == nil }

    /// Writes the history out as plain files in iCloud Drive.
    ///
    /// Long histories keep their metadata but not their media, so most of an
    /// archive is fetched back from CloudKit here rather than copied — which is
    /// why this reports progress and why it has to finish *before* anything is
    /// deleted.
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
                // Nothing is safe yet: iCloud Drive wasn't available, so the
                // folder only exists here until the user saves it somewhere.
                archiveToShare = outcome.folder
            }
            return outcome
        } catch {
            present(error)
            return nil
        }
    }

    // MARK: - Ending it

    /// Ends the link, cloud first, then locally.
    ///
    /// Order matters and is the whole point: if iCloud can't be cleaned up we
    /// keep the pairing, report why, and change nothing — because a local reset
    /// that leaves your photos in someone else's iCloud, while telling you it
    /// didn't, is the worst possible outcome here. `forceLocalReset` is the
    /// deliberate escape hatch for when someone wants out of this app *now* and
    /// will accept that.
    ///
    /// - Parameter startingOver: also forgets your name, leaving the app as it
    ///   was on install. Otherwise the name survives, so pairing again is one
    ///   step rather than two.
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

    /// Cuts this device loose without touching iCloud. For when the delete
    /// can't go through — no signal, an iCloud outage, an account that's been
    /// signed out — and waiting isn't acceptable. What stays behind in the
    /// other person's iCloud stays behind; the caller says so plainly.
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

    private func present(_ error: Error) {
        // The CKError code alongside the message, because the message alone
        // doesn't distinguish a transient failure from a real one — which is
        // the difference between "try again" and "the schema isn't deployed".
        let code = (error as? CKError).map { "CKError \($0.code.rawValue): " } ?? ""
        log.error("\(code, privacy: .public)\(error.localizedDescription, privacy: .public)")
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Holds a `UIBackgroundTaskIdentifier` so the expiration handler and the
/// normal completion path can both end it exactly once. A class because the
/// handler needs to reach the same identifier the caller stored after
/// `beginBackgroundTask` returned.
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
