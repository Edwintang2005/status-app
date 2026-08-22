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
    private(set) var accountStatus: CKAccountStatus?

    var errorMessage: String?
    /// Set briefly after a successful nudge so the UI can confirm it landed.
    var nudgeConfirmation: Date?

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

    // MARK: - Lifecycle

    func onLaunch() async {
        accountStatus = try? await CloudSync.shared.accountStatus()
        guard isPaired else { return }
        // Subscriptions are cheap to re-assert and easy to lose across
        // reinstalls, so confirm on every launch rather than only at pairing.
        try? await CloudSync.shared.registerSubscription()
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
        let name = snapshot.mine?.displayName ?? ""
        let payload = StatusPayload(
            emoji: emoji,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: name,
            updatedAt: Date(),
            nudgeCount: snapshot.mine?.nudgeCount ?? 0,
            lastNudgeAt: snapshot.mine?.lastNudgeAt
        )

        // Show it immediately; CloudKit catches up underneath.
        store.mutate { $0.mine = payload }
        reload()

        guard isPaired else { return }
        do {
            try await CloudSync.shared.publish(payload)
            reload()
        } catch {
            present(error)
        }
    }

    private func updateMyDisplayName(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = snapshot.mine ?? .initial(displayName: trimmed)
        var payload = existing
        payload.displayName = trimmed
        store.mutate { $0.mine = payload }
        reload()

        guard isPaired else { return }
        Task { [payload] in
            do { try await CloudSync.shared.publish(payload) } catch { present(error) }
        }
    }

    // MARK: - Nudge

    func sendNudge() async {
        guard canNudge else { return }
        do {
            if try await CloudSync.shared.sendNudge() {
                nudgeConfirmation = Date()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            reload()
        } catch {
            present(error)
            reload()
        }
    }

    // MARK: - Pairing

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

    func unpair() async {
        isBusy = true
        defer { isBusy = false }
        await CloudSync.shared.unpair()
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
