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
    private(set) var isBusy = false
    private(set) var isRefreshing = false
    private(set) var inviteURL: URL?
    /// Non-nil when the backend can't work — no iCloud account, and so on.
    private(set) var readinessMessage: String?
    /// The full moment history, newest first. Read from `MomentIndex` rather
    /// than the snapshot, which only carries the newest in each direction.
    private(set) var history: [Moment] = []

    var errorMessage: String?
    /// Set by the `tether://compose` deep link so the widget can open straight
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

    /// True in `make local` builds: no CloudKit, a fictional partner.
    let isLocalDemo = Backend.isLocalDemo

    #if TETHER_LOCAL_MODE
    /// Whether the demo controls are currently showing in Settings.
    ///
    /// They're hidden by default even in demo builds, so the app can be walked
    /// through — or screenshotted for the App Store — without a "Demo
    /// controls" section sitting in the middle of Settings. Persisted, so
    /// unlocking it once is enough for a working session.
    private(set) var isDemoUnlocked: Bool = SharedStore.shared.isDemoUnlocked

    func unlockDemoControls() {
        SharedStore.shared.isDemoUnlocked = true
        isDemoUnlocked = true
    }

    func hideDemoControls() {
        SharedStore.shared.isDemoUnlocked = false
        isDemoUnlocked = false
    }
    #endif

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

    #if TETHER_LOCAL_MODE
    /// Demo builds only. Stands in for the partner setting their *own* name on
    /// their own phone — there is no way to rename someone in the real app.
    var demoPartnerName: String {
        get { snapshot.theirs?.displayName ?? "" }
        set {
            store.mutate { $0.theirs?.displayName = newValue }
            reload()
        }
    }
    #endif

    var nudgeCooldownRemaining: TimeInterval {
        guard let last = snapshot.lastNudgeSentAt else { return 0 }
        return max(0, AppConfig.nudgeCooldown - Date().timeIntervalSince(last))
    }

    var canNudge: Bool { isPaired && nudgeCooldownRemaining == 0 }

    /// The newest photo or doodle in either direction — what the home card
    /// shows. Voice memos are deliberately excluded: they get their own short
    /// row, because a waveform stretched into a square photo frame is mostly
    /// empty space.
    var latestVisualMoment: Moment? {
        history.first { !$0.isVoice }
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
    func receiveInvite(_ metadata: CKShare.Metadata) {
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
        if case .unavailable(let message) = await Backend.current.readiness() {
            readinessMessage = message
        } else {
            readinessMessage = nil
        }
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

    func refresh() async {
        guard isPaired, !isRefreshing else { return }
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
            try await Backend.current.send(moment)
        } catch {
            present(error)
        }
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
            try await Backend.current.send(moment)
        } catch {
            present(error)
        }
    }

    // MARK: - Pairing

    #if TETHER_LOCAL_MODE
    /// Local builds skip invites entirely and pair with the fictional partner.
    func startDemo() async {
        isBusy = true
        defer { isBusy = false }
        // `hasName` gates the whole app, so by here there is always one.
        await LocalSync.shared.startDemo(displayName: myDisplayName)
        reload()
        await NotificationManager.requestAuthorizationIfNeeded()
    }

    func simulatePartnerStatus(emoji: String, message: String, isCelebration: Bool) async {
        await LocalSync.shared.simulatePartnerStatus(emoji: emoji,
                                                     message: message,
                                                     isCelebration: isCelebration)
        reload()
    }

    func simulatePartnerNudge() async {
        let name = await LocalSync.shared.simulatePartnerNudge()
        await NotificationManager.postNudge(from: name)
        reload()
    }

    func simulatePartnerMoment(image: UIImage, kind: Moment.Kind, caption: String) async {
        let moment = Moment(kind: kind,
                            caption: caption,
                            senderName: snapshot.theirs?.displayName ?? LocalSync.demoPartnerName,
                            fromMe: false)
        do {
            try MomentStore.shared.write(image, id: moment.id)
        } catch {
            present(error)
            return
        }
        await receiveFromDemoPartner(moment)
    }

    func simulatePartnerVoiceMemo(fileURL: URL,
                                  duration: TimeInterval,
                                  waveform: [Double],
                                  caption: String) async {
        let moment = Moment(kind: .voice,
                            caption: caption,
                            senderName: snapshot.theirs?.displayName ?? LocalSync.demoPartnerName,
                            fromMe: false,
                            duration: duration,
                            waveform: waveform)
        do {
            try MomentStore.shared.adoptAudio(from: fileURL, id: moment.id)
        } catch {
            present(error)
            return
        }
        await receiveFromDemoPartner(moment)
    }

    /// The tail end of every simulated arrival: file it, mark it announced so
    /// the next refresh doesn't double up, and raise the notification the real
    /// backend would have.
    private func receiveFromDemoPartner(_ moment: Moment) async {
        await LocalSync.shared.simulatePartnerMoment(moment)
        store.mutate(reloadWidgets: false) { $0.lastNotifiedMomentID = moment.id }
        await NotificationManager.postMoment(moment, from: snapshot.partnerDisplayName)
        reload()
    }
    #else
    func createInvite() async {
        isBusy = true
        defer { isBusy = false }
        do {
            inviteURL = try await CloudSync.shared.createPairInvite(displayName: myDisplayName)
            reload()
            await NotificationManager.requestAuthorizationIfNeeded()
        } catch {
            present(error)
        }
    }

    func lockPairing() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await CloudSync.shared.lockPairing()
            inviteURL = nil
        } catch {
            present(error)
        }
    }
    #endif

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
        inviteURL = nil
        pendingInvite = nil
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Errors

    private func present(_ error: Error) {
        log.error("\(error.localizedDescription)")
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
extension AppModel {
    /// A model backed by an isolated defaults suite, for previews.
    static func previewModel(paired: Bool = true) -> AppModel {
        let suite = UserDefaults(suiteName: "tether.preview.\(UUID().uuidString)")!
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
