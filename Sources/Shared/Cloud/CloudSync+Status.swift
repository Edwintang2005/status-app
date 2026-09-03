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

        try await withZoneRecovery(pairing) {
            do {
                try await saveStatus(payload, to: recordID, in: database)
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Another device of ours wrote first; reapply on the server copy.
                log.notice("Status conflict, retrying against server record.")
                try await saveStatus(payload, to: recordID, in: database)
            }
            // Separate save: the log wants overwrite semantics (`allKeys`), the
            // status a conflict check. A failure here still fails the publish,
            // so `republishStatusIfNeeded` retries both — each is idempotent.
            if logged {
                try await saveStatusLog(payload, role: pairing.role, zone: recordID.zoneID, in: database)
            }
        }

        await MainActor.run {
            _ = SharedStore.shared.mutate {
                // A publish finishing late must not revert a newer local status —
                // it would also pass `markStatusPublished`'s currency check for it.
                guard payload.updatedAt >= ($0.mine?.updatedAt ?? .distantPast) else { return }
                $0.mine = payload
            }
        }
        await pruneStatusLog(pairing, in: database)
    }

    /// The per-change history record. Named by the status's own timestamp, so
    /// republishing the same status lands on the same record.
    func saveStatusLog(_ payload: StatusPayload,
                               role: PairRole,
                               zone: CKRecordZone.ID,
                               in database: CKDatabase) async throws {
        let recordID = CKRecord.ID(recordName: role.statusLogRecordName(at: payload.updatedAt),
                                   zoneID: zone)
        let record = CKRecord(recordType: RecordType.statusLog, recordID: recordID)
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record[Field.updatedAt] = payload.updatedAt as CKRecordValue
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .allKeys)
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
        // Entries logged before the cloud log existed have no record; a
        // per-item unknownItem is the expected answer for those.
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            do {
                _ = try await database.modifyRecords(saving: [], deleting: batch)
            } catch let error as CKError where Self.isUnknownItem(error) {
                continue
            } catch {
                log.error("Status log prune failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        StatusHistoryLog.shared.remove(fromMe: true, at: stale.map(\.at))
        log.notice("Pruned \(stale.count) status log record(s).")
    }

    func saveStatus(_ payload: StatusPayload,
                            to recordID: CKRecord.ID,
                            in database: CKDatabase) async throws {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.status, recordID: recordID)
        // Never regress the server copy: a slow publish (or a republish from a
        // second device on the account) must lose to a newer status already there.
        if let current = record[Field.updatedAt] as? Date, current > payload.updatedAt {
            log.notice("Status save skipped: the server already has a newer status.")
            return
        }
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.displayName] = payload.displayName
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record[Field.updatedAt] = payload.updatedAt as CKRecordValue
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
    }
}
