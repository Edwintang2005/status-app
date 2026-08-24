import Foundation
import os

/// A stand-in for CloudKit that keeps everything on this device, so the whole
/// app — widgets included — can be exercised before an Apple Developer
/// account exists.
///
/// The "partner" is fictional. Everything you'd normally receive over the
/// network is instead produced by the demo controls in Settings, which call
/// `simulatePartner…` below. Nothing here ever touches the network.
actor LocalSync: SyncBackend {
    static let shared = LocalSync()

    private let log = Logger(subsystem: AppConfig.appGroupID, category: "LocalSync")

    static let demoPartnerName = "Sam"

    func readiness() async -> BackendReadiness { .ready }

    // MARK: - Pairing

    /// Instantly "pairs" with the fictional partner.
    func startDemo(displayName: String) async {
        await MainActor.run {
            let store = SharedStore.shared
            store.pairing = PairingInfo(role: .owner,
                                        zoneName: AppConfig.coupleZoneName,
                                        zoneOwnerName: "local-demo",
                                        pairedAt: Date())
            store.mutate { snapshot in
                snapshot.isPaired = true
                snapshot.lastSyncedAt = Date()
                snapshot.mine = .initial(displayName: displayName)
                snapshot.theirs = StatusPayload(
                    emoji: "🥰",
                    message: "missing you",
                    displayName: Self.demoPartnerName,
                    updatedAt: Date(),
                    nudgeCount: 0,
                    lastNudgeAt: nil
                )
            }
        }
    }

    // MARK: - SyncBackend

    func publish(_ payload: StatusPayload) async throws {
        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.mine = payload }
        }
    }

    /// Nothing arrives on its own in demo mode; the demo controls push changes
    /// straight into the store instead.
    func refresh() async throws -> RefreshResult {
        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.lastSyncedAt = Date() }
            return RefreshResult(partnerStatus: SharedStore.shared.snapshot.theirs)
        }
    }

    func sendNudge() async throws -> Bool {
        let now = Date()
        return await MainActor.run {
            let store = SharedStore.shared
            if let last = store.snapshot.lastNudgeSentAt,
               now.timeIntervalSince(last) < AppConfig.nudgeCooldown {
                return false
            }
            store.mutate { snapshot in
                snapshot.lastNudgeSentAt = now
                snapshot.mine?.nudgeCount += 1
                snapshot.mine?.lastNudgeAt = now
            }
            return true
        }
    }

    /// The files are already written; in demo mode "sending" is just keeping
    /// the local record.
    func send(_ moment: Moment) async throws {}

    /// Demo media only ever exists locally, so there is nowhere to fetch from.
    func fetchMedia(for moment: Moment) async throws {}

    func registerSubscription() async throws {}

    func unpair() async {
        await MainActor.run { SharedStore.shared.resetPairing() }
    }

    // MARK: - Demo controls

    /// Pretend the partner changed their status.
    func simulatePartnerStatus(emoji: String, message: String, isCelebration: Bool) async {
        await MainActor.run {
            _ = SharedStore.shared.mutate { snapshot in
                let existing = snapshot.theirs
                snapshot.theirs = StatusPayload(
                    emoji: emoji,
                    message: message,
                    displayName: existing?.displayName ?? Self.demoPartnerName,
                    updatedAt: Date(),
                    nudgeCount: existing?.nudgeCount ?? 0,
                    lastNudgeAt: existing?.lastNudgeAt,
                    isCelebration: isCelebration
                )
            }
        }
    }

    /// Pretend the partner nudged. Returns the name to announce.
    func simulatePartnerNudge() async -> String {
        await MainActor.run {
            let store = SharedStore.shared
            store.mutate { snapshot in
                snapshot.theirs?.nudgeCount += 1
                snapshot.theirs?.lastNudgeAt = Date()
                snapshot.lastSeenPartnerNudgeCount = snapshot.theirs?.nudgeCount ?? 0
            }
            return store.snapshot.partnerDisplayName
        }
    }

    /// Pretend the partner sent a photo, drawing or voice memo. The media file
    /// must already be written to `MomentStore` under `moment.id`.
    func simulatePartnerMoment(_ moment: Moment) async {
        await MainActor.run { SharedStore.shared.record(moment) }
    }
}
