import CloudKit
import Foundation
import os

// Publishing this device's status, plus the durable `StatusLog` record per change.
extension CloudSync {
    /// Writes this device's own status record. Only ever touches the record
    /// belonging to our own role, so the two phones can never conflict.
    func publish(_ payload: StatusPayload, logged: Bool) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.statusRecordName,
                                   zoneID: zoneID(for: pairing))

        let outcome = try await withZoneRecovery(pairing) {
            // Another device of ours, or an overlapping publish, may write first.
            try await retryingConflicts("Status") {
                try await saveStatus(payload, to: recordID, in: database)
            }
        }

        if case .superseded(let server) = outcome {
            // Surfaced, not swallowed: marking ours sent would show a status the
            // partner never gets. The newer one is adopted in its place.
            await MainActor.run {
                _ = SharedStore.shared.mutate { $0.adoptSupersedingStatus(server, over: payload) }
            }
            return
        }

        // The record is there: the status counts as sent from here, whatever
        // its log does — a failed log is retried alone (`Outbox.republishStatus`).
        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.recordPublished(payload, savedAt: outcome.savedAt) }
        }
        if logged {
            // Separate save: the log wants overwrite semantics (`allKeys`), the
            // status a conflict check. A failure still fails the publish.
            try await withZoneRecovery(pairing) {
                try await saveStatusLog(payload, role: pairing.role, zone: recordID.zoneID, in: database)
            }
            await MainActor.run {
                _ = SharedStore.shared.mutate(reloadWidgets: false) { $0.myStatusLoggedAt = payload.wordsAt }
            }
        }
        await pruneStatusLog(pairing, in: database)
    }

    enum StatusSaveOutcome: Sendable {
        /// Written now, or already there: the server's save time.
        case saved(Date?)
        case superseded(StatusPayload)

        var savedAt: Date? {
            if case .saved(let date) = self { return date }
            return nil
        }
    }

    /// The per-change history record. Named by when the words were set (not a
    /// later rename's stamp), so republishing the same status lands on the same record.
    func saveStatusLog(_ payload: StatusPayload,
                               role: PairRole,
                               zone: CKRecordZone.ID,
                               in database: CKDatabase) async throws {
        let recordID = CKRecord.ID(recordName: role.statusLogRecordName(at: payload.wordsAt),
                                   zoneID: zone)
        let record = CKRecord(recordType: RecordType.statusLog, recordID: recordID)
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record[Field.updatedAt] = payload.wordsAt as CKRecordValue
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .allKeys)
        try Self.confirmSaved(result, recordID)
    }

    /// Deletes this side's log records past `AppConfig.statusLogLimit`, oldest
    /// first, and drops them locally. Best effort: the cap is housekeeping, and
    /// the next publish tries again. Record names derive from the local log's
    /// own entries, so no query (and no index) is needed.
    func pruneStatusLog(_ pairing: PairingInfo, in database: CKDatabase) async {
        let own = StatusHistoryLog.shared.load().filter(\.fromMe)
        guard own.count > AppConfig.statusLogLimit else { return }
        let stale = Array(own[AppConfig.statusLogLimit...])
        let zone = zoneID(for: pairing)
        let ids = stale.map {
            CKRecord.ID(recordName: pairing.role.statusLogRecordName(at: $0.at), zoneID: zone)
        }
        // Entries logged before the cloud log existed have no record, and a
        // per-item unknownItem is the expected answer for those. Non-atomic, so
        // one such entry can't fail its whole batch (which left the cloud log
        // growing until those entries aged out); only what the server confirmed
        // gone — deleted or never there — leaves the local log.
        var removed: [Date] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            let dates = stale[start..<min(start + 200, stale.count)].map(\.at)
            do {
                let result = try await database.modifyRecords(saving: [], deleting: batch, atomically: false)
                for (id, date) in zip(batch, dates) {
                    switch result.deleteResults[id] {
                    case .success?:
                        removed.append(date)
                    case .failure(let error as CKError)? where error.code == .unknownItem:
                        removed.append(date)
                    default:
                        break
                    }
                }
            } catch {
                log.error("Status log prune failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        guard !removed.isEmpty else { return }
        StatusHistoryLog.shared.remove(fromMe: true, at: removed)
        log.notice("Pruned \(removed.count) status log record(s).")
    }

    func saveStatus(_ payload: StatusPayload,
                    to recordID: CKRecord.ID,
                    in database: CKDatabase) async throws -> StatusSaveOutcome {
        let existing = try await fetchRecord(recordID, in: database)
        // Never regress the server copy: a slow publish (or a republish from a
        // second device on the account) must lose to a newer status already there.
        let server = existing.flatMap { Self.payload(from: $0, nudge: nil, existing: nil, fromPartner: false) }
        let readable = existing.map(Self.isReadable) ?? true
        switch StatusSavePolicy.decide(server: server, serverReadable: readable, payload: payload, now: Date()) {
        case .unreadableNewer:
            log.notice("Status save waiting: the server's newer copy couldn't be read here.")
            throw SyncError.saveUnconfirmed
        case .alreadySaved:
            return .saved(existing?.modificationDate)
        case .superseded:
            log.notice("Status save skipped: the server already has a newer status.")
            if let server { return .superseded(server) }
        case .save:
            break
        }
        let record = existing ?? CKRecord(recordType: RecordType.status, recordID: recordID)
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.displayName] = payload.displayName
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record[Field.updatedAt] = payload.updatedAt as CKRecordValue
        // Change-tag checked, so a write that raced ours surfaces as
        // `serverRecordChanged` and `publish` retries on the fresh copy.
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .ifServerRecordUnchanged)
        return .saved(try Self.confirmSaved(result, recordID).modificationDate)
    }
}

extension Snapshot {
    /// `payload` reached the server. A late finish never reverts a newer local
    /// status, and the nudge fields stay the store's: another process (the
    /// lock-screen heart) may have written them since `payload` was built.
    mutating func recordPublished(_ payload: StatusPayload, savedAt: Date?) {
        markStatusPublished(payload)
        guard payload.updatedAt >= (mine?.updatedAt ?? .distantPast) else { return }
        var published = payload
        published.serverSavedAt = savedAt.map { $0.wholeSeconds }
        if let mine {
            published.nudgeCount = mine.nudgeCount
            published.lastNudgeAt = mine.lastNudgeAt
        }
        mine = published
    }

    /// Our save lost to a newer status on the server: that one is ours now —
    /// unless a newer local edit landed meanwhile, which publishes on its own.
    mutating func adoptSupersedingStatus(_ server: StatusPayload, over payload: StatusPayload) {
        guard let held = mine, held.updatedAt == payload.updatedAt else { return }
        var adopted = server
        adopted.nudgeCount = held.nudgeCount
        adopted.lastNudgeAt = held.lastNudgeAt
        mine = adopted
        myStatusPublished = true
        myStatusLoggedAt = adopted.wordsAt
    }
}
