import Foundation
import Observation
import os

/// The offline-send recovery loops (CLAUDE.md invariants 11, 13, 16): status,
/// anniversary and request republishes, pending uploads, and the receipt flush.
/// Every collaborator is injected so the loops run against a fake backend and
/// throwaway stores under `make test`; `AppModel` owns one over the real ones.
/// Each method returns whether local state changed, so the caller can re-read.
@MainActor
@Observable
final class Outbox {
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored private let index: MomentIndex
    @ObservationIgnored private let backend: () -> any SyncBackend
    @ObservationIgnored private let hasMedia: (Moment) -> Bool
    /// Wraps each upload: the app's UIKit background task, a pass-through in tests.
    @ObservationIgnored private let protect: @MainActor (String, @MainActor () async throws -> Void) async throws -> Void
    /// Runs after the index lost an entry: `SharedStore.refreshDerived` in the app.
    @ObservationIgnored private let indexChanged: () -> Void
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.appGroupID, category: "Outbox")

    /// Observed: the home footer shows "Sending…" while it runs.
    private(set) var isRetryingUploads = false
    /// When a send last failed on a full iCloud (`SendFailure.storageFull`). In
    /// memory: after a relaunch one retry finds out again.
    private(set) var storageFullAt: Date?

    @ObservationIgnored private var isRepublishingStatus = false
    @ObservationIgnored private var isRepublishingAnniversary = false
    @ObservationIgnored private var isRepublishingRequest = false
    @ObservationIgnored private var isFlushingReceipts = false

    init(store: SharedStore,
         index: MomentIndex,
         backend: @escaping () -> any SyncBackend,
         hasMedia: @escaping (Moment) -> Bool,
         protect: @escaping @MainActor (String, @MainActor () async throws -> Void) async throws -> Void,
         indexChanged: @escaping () -> Void) {
        self.store = store
        self.index = index
        self.backend = backend
        self.hasMedia = hasMedia
        self.protect = protect
        self.indexChanged = indexChanged
    }

    // MARK: - Send outcomes

    /// Stamps a full iCloud, which slows automatic retries and changes the wording.
    @discardableResult
    func noteSendFailed(_ error: Error) -> SendFailure {
        let failure = SendFailure(error)
        if failure == .storageFull { storageFullAt = Date() }
        return failure
    }

    /// Anything landing proves there's room again.
    func noteSendSucceeded() {
        storageFullAt = nil
    }

    nonisolated static func automaticRetryAllowed(storageFullAt: Date?, now: Date) -> Bool {
        guard let full = storageFullAt, full <= now else { return true }
        return now.timeIntervalSince(full) >= AppConfig.storageFullRetryInterval
    }

    // MARK: - Republishes

    /// The local status, if its last publish never landed. Safe to re-run:
    /// `publish` overwrites a fixed record name, and only this device writes it.
    @discardableResult
    func republishStatus() async -> Bool {
        guard store.pairing != nil, !isRepublishingStatus else { return false }
        let snapshot = store.snapshot
        guard !snapshot.myStatusPublished, let mine = snapshot.mine else { return false }
        isRepublishingStatus = true
        defer { isRepublishingStatus = false }
        // Logged only if this status's log record isn't confirmed yet: a
        // retried rename must not log its old words as a new status.
        let logged = snapshot.myStatusLoggedAt != mine.wordsAt
        let backend = backend()
        do {
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publish(mine, logged: logged) }
            store.mutate(reloadWidgets: false) { $0.markStatusPublished(mine) }
            noteSendSucceeded()
            log.info("Republished the offline status update")
            return true
        } catch {
            noteSendFailed(error)
            log.error("Status republish failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Owner only: one fixed record name, and only the owner writes it.
    @discardableResult
    func republishAnniversary() async -> Bool {
        guard store.pairing?.role == .owner, !isRepublishingAnniversary else { return false }
        let snapshot = store.snapshot
        guard !snapshot.anniversaryPublished else { return false }
        isRepublishingAnniversary = true
        defer { isRepublishingAnniversary = false }
        let anniversary = snapshot.anniversary
        let backend = backend()
        do {
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publishAnniversary(anniversary) }
            store.mutate(reloadWidgets: false) { $0.markAnniversaryPublished(anniversary) }
            log.info("Republished the offline anniversary update")
            return true
        } catch {
            noteSendFailed(error)
            log.error("Anniversary republish failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Participant only; re-asking overwrites.
    @discardableResult
    func republishAnniversaryRequest() async -> Bool {
        guard store.pairing?.role == .participant, !isRepublishingRequest else { return false }
        let snapshot = store.snapshot
        guard !snapshot.anniversaryRequestPublished, let date = snapshot.anniversaryRequestedAt else { return false }
        isRepublishingRequest = true
        defer { isRepublishingRequest = false }
        let backend = backend()
        do {
            try await withDeadline(AppConfig.publishDeadline) { try await backend.publishAnniversaryRequest(at: date) }
            store.mutate(reloadWidgets: false) { $0.markAnniversaryRequestPublished(date) }
            log.info("Republished the offline anniversary request")
            return true
        } catch {
            noteSendFailed(error)
            log.error("Anniversary request republish failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Pending uploads

    /// Re-sends own moments whose upload never completed; quiet on failure (the
    /// footer says so). Safe to re-run — `send` overwrites a deterministic
    /// record name. `automatic` passes are held off for a while after a full iCloud.
    @discardableResult
    func retryPendingUploads(automatic: Bool, now: Date = Date()) async -> Bool {
        guard store.pairing != nil, !isRetryingUploads else { return false }
        if automatic, !Self.automaticRetryAllowed(storageFullAt: storageFullAt, now: now) { return false }
        let pending = index.load().filter { $0.fromMe && !$0.uploaded }
        guard !pending.isEmpty else { return false }
        isRetryingUploads = true
        defer { isRetryingUploads = false }

        let backend = backend()
        var changed = false
        for moment in pending {
            // Pruned/wiped media can never be delivered; drop the ghost entry
            // rather than retrying forever or falsely marking it uploaded.
            guard hasMedia(moment) else {
                log.error("Dropping pending moment \(moment.id, privacy: .public): its media is gone.")
                index.remove(id: moment.id)
                indexChanged()
                changed = true
                continue
            }
            do {
                // Bookkeeping inside `protect`: ending the assertion lets iOS
                // suspend, and a file lock taken after it is a 0xdead10cc kill.
                try await protect("moment-retry") { [index] in
                    try await withDeadline(AppConfig.uploadDeadline) { try await backend.send(moment) }
                    _ = index.markUploaded(ids: [moment.id])
                }
                noteSendSucceeded()
                changed = true
                log.info("Retried upload of \(moment.id, privacy: .public) successfully")
            } catch {
                log.error("Retry upload of \(moment.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                // The rest would hit the same full iCloud.
                if noteSendFailed(error) == .storageFull { break }
            }
        }
        return changed
    }

    // MARK: - Read receipts

    /// Seen-state of the partner's moments, newest first, capped. `.distantPast`
    /// marks entries seen before per-moment timestamps existed ("seen", no time).
    nonisolated static func seenMap(from history: [Moment], limit: Int = AppConfig.receiptMapLimit) -> [String: Date] {
        var map: [String: Date] = [:]
        for moment in history where !moment.fromMe && moment.seen {
            map[moment.id] = moment.seenAt ?? .distantPast
            if map.count >= limit { break }
        }
        return map
    }

    /// Publishes this device's receipts while they're dirty. The flag is claimed
    /// before the network call, like the nudge cooldown: a `markSeen` or toggle
    /// landing mid-flight re-dirties it and the loop publishes that too; a
    /// failure re-sets it for the next refresh. Disabled publishes an empty map.
    func flushReceipts() async {
        guard store.pairing != nil, !isFlushingReceipts else { return }
        isFlushingReceipts = true
        defer { isFlushingReceipts = false }
        let backend = backend()
        while store.claimReceiptsDirty() {
            let enabled = store.readReceiptsEnabled
            let map = enabled ? Self.seenMap(from: index.load()) : [:]
            let statusSeen = enabled ? store.snapshot.partnerStatusSeen : nil
            do {
                try await withDeadline(AppConfig.publishDeadline) {
                    try await backend.publishReceipts(map, statusSeen: statusSeen)
                }
            } catch {
                noteSendFailed(error)
                log.error("Receipt publish failed: \(error.localizedDescription, privacy: .public)")
                store.mutate(reloadWidgets: false) { $0.receiptsDirty = true }
                return
            }
        }
    }
}

// MARK: - The flags' rules

extension Snapshot {
    /// Invariant 16: a late-finishing publish must not mark a newer offline edit delivered.
    mutating func markStatusPublished(_ payload: StatusPayload) {
        guard mine?.updatedAt == payload.updatedAt else { return }
        myStatusPublished = true
    }

    mutating func markAnniversaryPublished(_ published: Anniversary?) {
        guard anniversary == published else { return }
        anniversaryPublished = true
    }

    mutating func markAnniversaryRequestPublished(_ date: Date) {
        guard anniversaryRequestedAt == date else { return }
        anniversaryRequestPublished = true
    }

    /// `true` (and cleared) when receipts were waiting to publish.
    mutating func claimReceiptsDirty() -> Bool {
        guard receiptsDirty else { return false }
        receiptsDirty = false
        return true
    }

    /// The status read receipt for the status `shown` on screen, forward only:
    /// a re-delivered older status must not re-stamp. `true` when it moved (and
    /// receipts are now dirty).
    mutating func stampPartnerStatusSeen(_ shown: StatusPayload?, at now: Date) -> Bool {
        guard let theirs = shown, theirs.updatedAt > .distantPast,
              (partnerStatusSeen?.statusUpdatedAt ?? .distantPast) < theirs.updatedAt else { return false }
        partnerStatusSeen = StatusSeen(statusUpdatedAt: theirs.updatedAt, seenAt: now)
        receiptsDirty = true
        return true
    }
}

extension SharedStore {
    /// `Snapshot.claimReceiptsDirty` under the snapshot lock.
    func claimReceiptsDirty() -> Bool {
        var claimed = false
        mutate(reloadWidgets: false) { claimed = $0.claimReceiptsDirty() }
        return claimed
    }
}
