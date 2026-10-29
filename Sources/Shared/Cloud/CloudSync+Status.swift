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
        // Never the current status's own log, which can't be saved and deleted at once anyway.
        let logName = pairing.role.statusLogRecordName(at: payload.wordsAt)
        var stale = staleStatusLogs(pairing).filter { $0.id.recordName != logName }
        if logged {
            // Separate save: the log wants overwrite semantics (`allKeys`), the
            // status a conflict check. A failure still fails the publish. The
            // prune's first batch rides along.
            let folded = Array(stale.prefix(Self.statusLogPruneBatch))
            let removed = try await withZoneRecovery(pairing) {
                try await saveStatusLog(payload, role: pairing.role, zone: recordID.zoneID,
                                        pruning: folded, in: database)
            }
            await MainActor.run {
                _ = SharedStore.shared.mutate(reloadWidgets: false) { $0.recordLogged(payload) }
            }
            noteStatusLogsPruned(removed)
            let foldedNames = Set(folded.map(\.id.recordName))
            stale.removeAll { foldedNames.contains($0.id.recordName) }
        }
        await pruneStatusLog(stale, in: database)
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
    /// `pruning` is deleted in the same request; returns the dates confirmed gone.
    func saveStatusLog(_ payload: StatusPayload,
                       role: PairRole,
                       zone: CKRecordZone.ID,
                       pruning stale: [StaleStatusLog] = [],
                       in database: CKDatabase) async throws -> [Date] {
        let recordID = CKRecord.ID(recordName: role.statusLogRecordName(at: payload.wordsAt),
                                   zoneID: zone)
        let record = CKRecord(recordType: RecordType.statusLog, recordID: recordID)
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record[Field.updatedAt] = payload.wordsAt as CKRecordValue
        // Non-atomic once deletions ride along: a pre-cloud entry's unknownItem
        // must not fail the log.
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: stale.map(\.id),
                                                      savePolicy: .allKeys,
                                                      atomically: stale.isEmpty)
        try Self.confirmSaved(result, recordID)
        return Self.confirmedPrunes(result, stale)
    }

    /// One of this side's log records past the cap, and its local entry's date.
    struct StaleStatusLog: Sendable {
        var id: CKRecord.ID
        var at: Date
    }

    /// Deletions per request, well inside CloudKit's 400-item limit.
    static let statusLogPruneBatch = 200

    /// This side's log records past `AppConfig.statusLogLimit`, oldest last.
    /// Record names derive from the local log's own entries, so no query (and
    /// no index) is needed.
    func staleStatusLogs(_ pairing: PairingInfo) -> [StaleStatusLog] {
        let own = StatusHistoryLog.shared.load().filter(\.fromMe)
        guard own.count > AppConfig.statusLogLimit else { return [] }
        let zone = zoneID(for: pairing)
        return own[AppConfig.statusLogLimit...].map {
            StaleStatusLog(id: CKRecord.ID(recordName: pairing.role.statusLogRecordName(at: $0.at), zoneID: zone),
                           at: $0.at)
        }
    }

    /// Deletes stale log records and drops them locally. Best effort: the cap
    /// is housekeeping, and the next publish tries again.
    func pruneStatusLog(_ stale: [StaleStatusLog], in database: CKDatabase) async {
        for batch in stale.chunked(into: Self.statusLogPruneBatch) {
            do {
                // Non-atomic: entries from before the cloud log have no record.
                let result = try await database.modifyRecords(saving: [], deleting: batch.map(\.id), atomically: false)
                noteStatusLogsPruned(Self.confirmedPrunes(result, batch))
            } catch {
                log.error("Status log prune failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    /// Only what the server confirmed gone (or never had) leaves the local log.
    static func confirmedPrunes(_ result: ModifyResult, _ stale: [StaleStatusLog]) -> [Date] {
        stale.compactMap { entry in
            switch result.deleteResults[entry.id] {
            case .success?:
                return entry.at
            case .failure(let error as CKError)? where error.code == .unknownItem:
                return entry.at
            default:
                return nil
            }
        }
    }

    func noteStatusLogsPruned(_ removed: [Date]) {
        guard !removed.isEmpty else { return }
        StatusHistoryLog.shared.remove(fromMe: true, at: removed)
        log.notice("Pruned \(removed.count) status log record(s).")
    }

    func saveStatus(_ payload: StatusPayload,
                    to recordID: CKRecord.ID,
                    in database: CKDatabase) async throws -> StatusSaveOutcome {
        // One round trip from the cached record when it says "save": the change tag
        // proves it current, and a stale one falls back to the fetch below. Any
        // other verdict is re-judged on a fetched copy.
        if let cached = await MainActor.run(body: { SharedStore.shared.statusRecordCache }),
           let record = Self.record(fromSystemFields: cached.systemFields), record.recordID == recordID,
           StatusSavePolicy.decide(server: cached.payload, payload: payload, now: Date()) == .save {
            do {
                return try await writeStatus(payload, onto: record, in: database)
            } catch let error as CKError where Self.isServerRecordChanged(error) || Self.isUnknownItem(error) {
                log.notice("Cached status record was stale; fetching.")
                await MainActor.run { SharedStore.shared.statusRecordCache = nil }
            }
        }
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
            if let existing, let server { await cacheStatusRecord(existing, payload: server) }
            return .saved(existing?.modificationDate)
        case .superseded:
            log.notice("Status save skipped: the server already has a newer status.")
            if let server { return .superseded(server) }
        case .save:
            break
        }
        return try await writeStatus(payload,
                                     onto: existing ?? CKRecord(recordType: RecordType.status, recordID: recordID),
                                     in: database)
    }

    private func writeStatus(_ payload: StatusPayload,
                             onto record: CKRecord,
                             in database: CKDatabase) async throws -> StatusSaveOutcome {
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.displayName] = payload.displayName
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record.encryptedValues[Field.celebrationStyle] = payload.celebration?.rawValue
        record[Field.updatedAt] = payload.updatedAt as CKRecordValue
        // Change-tag checked, so a write that raced ours surfaces as
        // `serverRecordChanged` and `publish` retries on the fresh copy.
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .ifServerRecordUnchanged)
        let saved = try Self.confirmSaved(result, record.recordID)
        await cacheStatusRecord(saved, payload: payload)
        return .saved(saved.modificationDate)
    }

    /// Our status record as saved, or as a delta carried it (another device of
    /// ours, or our own echo). Readable copies only: the cache's verdict needs the words.
    func cacheStatusRecord(_ record: CKRecord, payload: StatusPayload) async {
        let cache = SharedStore.StatusRecordCache(systemFields: Self.systemFields(of: record), payload: payload)
        await MainActor.run { SharedStore.shared.statusRecordCache = cache }
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

    /// The `StatusLog` record for `payload` landed. Only while it's still the
    /// current status: a slow publish finishing after a newer one was logged
    /// must not move the mark back and owe that one's log again (invariant 16).
    mutating func recordLogged(_ payload: StatusPayload) {
        guard mine?.wordsAt == payload.wordsAt else { return }
        myStatusLoggedAt = payload.wordsAt
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
