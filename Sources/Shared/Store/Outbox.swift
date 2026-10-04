import Foundation
import Observation
import os

/// The offline-send recovery loops (CLAUDE.md invariants 11, 13, 16): status,
/// anniversary and request republishes, pending uploads, the receipt flush, and
/// the fresh start's steps (its record's writes and this device's clear).
/// Every collaborator is injected so the loops run against a fake backend and
/// throwaway stores under `make test`; `AppModel` owns one over the real ones.
/// Each method returns whether local state changed, so the caller can re-read.
@MainActor
@Observable
final class Outbox {
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored private let index: MomentIndex
    @ObservationIgnored private let statusLog: StatusHistoryLog
    @ObservationIgnored private let backend: () -> any SyncBackend
    @ObservationIgnored private let hasMedia: (Moment) -> Bool
    /// Wraps each upload: the app's UIKit background task, a pass-through in tests.
    @ObservationIgnored private let protect: @MainActor (String, @MainActor () async throws -> Void) async throws -> Void
    /// Runs after the index lost an entry: `SharedStore.refreshDerived` in the app.
    @ObservationIgnored private let indexChanged: () -> Void
    /// Drops a moment's files: `MomentStore.delete` in the app.
    @ObservationIgnored private let deleteMedia: (String) -> Void
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

    /// Observed: the fresh start sheet shows "Clearing…" while it runs.
    private(set) var isClearingHistory = false
    /// Why this device's last clear stopped short; `nil` once one finishes.
    private(set) var freshStartFailure: String?
    @ObservationIgnored private var isAdvancingFreshStart = false

    init(store: SharedStore,
         index: MomentIndex,
         statusLog: StatusHistoryLog,
         backend: @escaping () -> any SyncBackend,
         hasMedia: @escaping (Moment) -> Bool,
         deleteMedia: @escaping (String) -> Void,
         protect: @escaping @MainActor (String, @MainActor () async throws -> Void) async throws -> Void,
         indexChanged: @escaping () -> Void) {
        self.store = store
        self.index = index
        self.statusLog = statusLog
        self.backend = backend
        self.hasMedia = hasMedia
        self.deleteMedia = deleteMedia
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
        // Not while clearing: a send the clear is deleting would come straight back.
        guard store.pairing != nil, !isRetryingUploads, !isClearingHistory else { return false }
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
                // The rest would hit the same full iCloud, or the same missing route.
                let failure = noteSendFailed(error)
                if failure == .storageFull || failure == .offline { break }
            }
        }
        return changed
    }

    // MARK: - Fresh start

    /// Sent now or not at all — never queued: the epoch is when the ask reaches
    /// iCloud, so an ask sent hours later would clear what arrived meanwhile.
    /// `false` when something else is still waiting to send, or the record moved on.
    func askForFreshStart() async throws -> Bool {
        guard store.pairing != nil, store.snapshot.freshStart.pendingIntent == nil else { return false }
        let backend = backend()
        let result = try await withDeadline(AppConfig.publishDeadline) { try await backend.publishFreshStart(.ask) }
        store.mutate(reloadWidgets: false) { $0.freshStart.asked(result) }
        if case .refused = result { return false }
        return true
    }

    /// Applies `intent` to the local copy and sends it; a failure leaves it
    /// queued for the next pass. `nil` when it can't apply to what's held or
    /// didn't land; a refusal comes back with the server's copy already adopted.
    @discardableResult
    func publishFreshStart(_ intent: FreshStartIntent) async -> FreshStartPublishResult? {
        guard store.pairing != nil else { return nil }
        var began = false
        store.mutate(reloadWidgets: false) { began = $0.freshStart.begin(intent) }
        guard began else { return nil }
        let backend = backend()
        do {
            let result = try await withDeadline(AppConfig.publishDeadline) { try await backend.publishFreshStart(intent) }
            store.mutate(reloadWidgets: false) { $0.freshStart.published(intent, result) }
            return result
        } catch {
            noteSendFailed(error)
            log.error("Fresh start publish failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Moves the fresh start on a step at a time (`FreshStartPolicy.nextStep`):
    /// a queued write, the asker's commit, a both-asked conversion, this
    /// device's clear and its completion. App only. `true` when anything moved.
    @discardableResult
    func advanceFreshStart() async -> Bool {
        guard let role = store.pairing?.role, !isAdvancingFreshStart else { return false }
        isAdvancingFreshStart = true
        defer { isAdvancingFreshStart = false }
        var changed = false
        // Bounded: every step either moves the state on or ends the pass.
        for _ in 0..<6 {
            guard let step = FreshStartPolicy.nextStep(store.snapshot.freshStart, role: role) else { break }
            switch step {
            case .publish(let intent):
                guard await publishFreshStart(intent) != nil else { return changed }
            case .clear(let epoch):
                guard await clearHistory(before: epoch) else { return changed }
            }
            changed = true
        }
        return changed
    }

    /// The zone half first; this device's own copy only once it's done, so a
    /// failed pass leaves nothing half-cleared here and simply runs again.
    /// Never on a locked phone: without the keys the commit can't be re-read.
    private func clearHistory(before epoch: Date) async -> Bool {
        guard let pairing = store.pairing, SharedStore.protectedDataAvailable,
              !isRetryingUploads, !isClearingHistory else { return false }
        isClearingHistory = true
        defer { isClearingHistory = false }
        let keep = store.snapshot.mine?.wordsAt
        let backend = backend()
        var cleared = false
        do {
            // Bookkeeping inside `protect` too (invariant 19): locking the phone
            // right after agreeing mustn't suspend this between its file writes.
            try await protect("fresh-start") { [self] in
                let zone = try await withDeadline(AppConfig.freshStartDeadline) {
                    try await backend.clearHistory(before: epoch, keepingStatusLogAt: keep)
                }
                guard store.pairing?.sameZone(as: pairing) == true else { return }
                // Unreadable isn't empty (invariant 15): nothing is judged against a blank list.
                guard let moments = index.loadReadable() else {
                    freshStartFailure = String(localized: "This iPhone's history couldn't be read just now.")
                    return
                }
                let snapshot = store.snapshot
                let keeping = Set([snapshot.mine.map { FreshStartPolicy.LogKey(fromMe: true, at: $0.wordsAt) },
                                   snapshot.theirs.map { FreshStartPolicy.LogKey(fromMe: false, at: $0.wordsAt) }]
                    .compactMap { $0 })
                let purge = FreshStartPolicy.purge(moments: moments, log: statusLog.load(), zone: zone,
                                                   epoch: epoch, keeping: keeping)
                index.remove(ids: Set(purge.momentIDs))
                purge.momentIDs.forEach(deleteMedia)
                statusLog.remove(fromMe: true, at: purge.myLogs)
                statusLog.remove(fromMe: false, at: purge.theirLogs)
                indexChanged()
                // The receipt record went with the clear; what's left is published afresh.
                store.mutate {
                    $0.freshStart.finished(epoch)
                    $0.receiptsDirty = true
                }
                freshStartFailure = nil
                cleared = true
                log.notice("Fresh start: cleared \(purge.momentIDs.count) moments and \(purge.myLogs.count + purge.theirLogs.count) statuses here.")
            }
        } catch {
            freshStartFailure = error is CancellationError
                ? String(localized: "iCloud took too long to answer.")
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Fresh start clear failed: \(error.localizedDescription, privacy: .public)")
        }
        return cleared
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

    /// Own records changed here that haven't reached iCloud yet — counted in the
    /// home footer beside pending moments. Mirrors the republish guards.
    func unpublishedCount(role: PairRole) -> Int {
        var count = myStatusPublished || mine == nil ? 0 : 1
        if role == .owner, !anniversaryPublished { count += 1 }
        if role == .participant, !anniversaryRequestPublished, anniversaryRequestedAt != nil { count += 1 }
        if freshStart.pendingIntent != nil { count += 1 }
        return count
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
