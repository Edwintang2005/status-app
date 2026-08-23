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

    var errorMessage: String?
    /// Set by the `tether://compose` deep link so the widget can open straight
    /// into the composer.
    var pendingComposer = false

    /// True in `make local` builds: no CloudKit, a fictional partner.
    let isLocalDemo = Backend.isLocalDemo

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

    var myDisplayName: String {
        get { snapshot.mine?.displayName ?? "" }
        set { updateMyDisplayName(newValue) }
    }

    var partnerNickname: String {
        get { snapshot.partnerNickname ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.mutate { $0.partnerNickname = trimmed.isEmpty ? nil : trimmed }
            reload()
        }
    }

    var nudgeCooldownRemaining: TimeInterval {
        guard let last = snapshot.lastNudgeSentAt else { return 0 }
        return max(0, AppConfig.nudgeCooldown - Date().timeIntervalSince(last))
    }

    var canNudge: Bool { isPaired && nudgeCooldownRemaining == 0 }

    var latestPartnerMoment: Moment? { snapshot.latestPartnerMoment }

    // MARK: - Lifecycle

    func onLaunch() async {
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
            // Background refreshes fail routinely (no signal, iCloud hiccup).
            // The "Synced …" footer already shows staleness, so don't throw a
            // modal alert over a screen the user didn't ask to refresh.
            log.error("Refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Status

    func setStatus(emoji: String, message: String) async {
        let payload = StatusPayload(
            emoji: emoji,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: snapshot.mine?.displayName ?? "",
            updatedAt: Date(),
            nudgeCount: snapshot.mine?.nudgeCount ?? 0,
            lastNudgeAt: snapshot.mine?.lastNudgeAt
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
        let name = snapshot.mine?.displayName.isEmpty == false
            ? snapshot.mine!.displayName
            : UIDevice.current.name
        await LocalSync.shared.startDemo(displayName: name)
        reload()
        await NotificationManager.requestAuthorizationIfNeeded()
    }

    func simulatePartnerStatus(emoji: String, message: String) async {
        await LocalSync.shared.simulatePartnerStatus(emoji: emoji, message: message)
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
                            senderName: LocalSync.demoPartnerName,
                            fromMe: false)
        do {
            try MomentStore.shared.write(image, id: moment.id)
        } catch {
            present(error)
            return
        }
        await LocalSync.shared.simulatePartnerMoment(moment)
        store.mutate(reloadWidgets: false) { $0.lastSeenMomentID = moment.id }
        await NotificationManager.postMoment(moment, from: snapshot.partnerDisplayName)
        reload()
    }
    #else
    func createInvite() async {
        isBusy = true
        defer { isBusy = false }
        let name = snapshot.mine?.displayName.isEmpty == false
            ? snapshot.mine!.displayName
            : UIDevice.current.name
        do {
            inviteURL = try await CloudSync.shared.createPairInvite(displayName: name)
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

    func unpair() async {
        isBusy = true
        defer { isBusy = false }
        await Backend.current.unpair()
        inviteURL = nil
        reload()
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
