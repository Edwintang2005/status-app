import CloudKit
import Foundation
import os

// The heart. Claims the cooldown under the lock before any network call
// (CLAUDE.md invariant 7).
extension CloudSync {
    /// Writes the partner-visible nudge record. Its own record type, so its
    /// subscription can carry a real alert. Returns `false` if the cooldown hasn't elapsed.
    @discardableResult
    func sendNudge() async throws -> Bool {
        let store = SharedStore.shared
        // Whole seconds: `now` is read back from the snapshot (ISO-8601, no
        // fraction) in the failure path and compared for equality.
        let now = Date().wholeSeconds

        // Check and claim inside one `mutate` under the cross-process lock: the
        // app and the widget intent run in different processes, and an unlocked
        // check let two nudges through one cooldown.
        let allowed = await MainActor.run { () -> Bool in
            var claimed = false
            _ = store.mutate(reloadWidgets: false) { snapshot in
                if let last = snapshot.lastNudgeSentAt,
                   now.timeIntervalSince(last) < AppConfig.nudgeCooldown {
                    return
                }
                // Claim the cooldown before the network call so a double-tap
                // can't slip a second nudge through mid-flight.
                snapshot.lastNudgeSentAt = now
                // A retry is underway; the failure notice has done its job.
                snapshot.lastNudgeFailedAt = nil
                claimed = true
            }
            return claimed
        }
        guard allowed else { return false }

        do {
            let pairing = try await requirePairing()
            let database = self.database(for: pairing)
            let recordID = CKRecord.ID(recordName: pairing.role.nudgeRecordName,
                                       zoneID: zoneID(for: pairing))

            return try await withZoneRecovery(pairing) {
                let next = try await saveNudge(to: recordID, in: database, at: now)
                await MainActor.run {
                    _ = store.mutate { snapshot in
                        snapshot.mine?.nudgeCount = next
                        snapshot.mine?.lastNudgeAt = now
                        snapshot.lastNudgeFailedAt = nil
                    }
                }
                return true
            }
        } catch {
            // Release the cooldown for immediate retry and record the failure —
            // the lock-screen widget has no other way to show an offline tap
            // didn't send. Only if our own claim is still standing: another
            // process may have claimed (and sent) since, and clearing that
            // live cooldown would let a second nudge straight through.
            await MainActor.run {
                _ = store.mutate { snapshot in
                    guard snapshot.lastNudgeSentAt == now else { return }
                    snapshot.lastNudgeSentAt = nil
                    snapshot.lastNudgeFailedAt = Date()
                    // Handed over but refused: no ✓ beside the failure.
                    if let issued = snapshot.lastNudgeIssuedAt, issued >= now { snapshot.lastNudgeIssuedAt = nil }
                }
            }
            throw error
        }
    }

    /// Increments and saves the nudge record; returns the new count. Built on
    /// the cached copy (`SharedStore.nudgeRecordCache`), so the lock-screen
    /// heart's whole send is one round trip inside its budget; a conflict hands
    /// back the server's copy to count on (invariant 16, three attempts in all),
    /// and a cached record that's gone is fetched, not read as the zone gone.
    func saveNudge(to recordID: CKRecord.ID,
                   in database: CKDatabase,
                   at now: Date) async throws -> Int {
        var record: CKRecord
        var fromCache = false
        if let cached = await MainActor.run(body: { SharedStore.shared.nudgeRecordCache }),
           let copy = Self.record(fromSystemFields: cached.systemFields), copy.recordID == recordID {
            copy[Field.count] = cached.count as CKRecordValue
            record = copy
            fromCache = true
        } else {
            record = try await fetchRecord(recordID, in: database)
                ?? CKRecord(recordType: RecordType.nudge, recordID: recordID)
        }
        for attempt in 1...3 {
            // The intent's deadline cancels rather than waits; the failure path
            // must get to release the cooldown before WidgetKit suspends us.
            try Task.checkCancellation()
            // Clamped: the share lets the partner write this record too, and a
            // planted `Int.max` would trap the increment on every tap.
            let next = min(max(record[Field.count] as? Int ?? 0, 0), AppConfig.nudgeCountCeiling) + 1
            record[Field.count] = next as CKRecordValue
            record[Field.sentAt] = now as CKRecordValue
            do {
                // Stamped before the hand-off, so a deadline after it never reads as a failure.
                await MainActor.run {
                    _ = SharedStore.shared.mutate(reloadWidgets: false) { $0.lastNudgeIssuedAt = Date().wholeSeconds }
                }
                let saved = try await Self.saveNudgeRecord(record, in: database)
                await MainActor.run {
                    SharedStore.shared.nudgeRecordCache = .init(systemFields: Self.systemFields(of: saved), count: next)
                }
                return next
            } catch let error as CKError where attempt < 3 && Self.isServerRecordChanged(error) {
                log.notice("Nudge conflict (attempt \(attempt)); counting on the server copy.")
                if let server = error.serverRecord {
                    record = server
                } else if let fetched = try await fetchRecord(recordID, in: database) {
                    record = fetched
                } else {
                    throw error
                }
            } catch let error as CKError where fromCache && Self.isUnknownItem(error) {
                fromCache = false
                record = try await fetchRecord(recordID, in: database)
                    ?? CKRecord(recordType: RecordType.nudge, recordID: recordID)
            }
        }
        throw SyncError.saveUnconfirmed
    }

    /// Long-lived and never cancelled once handed over: iCloud finishes it even
    /// if the widget's process is suspended or ended, so a tap lands promptly
    /// instead of when the extension next wakes. Confirmed by the record's own
    /// result (invariant 22); change-tag checked, as two racing taps would
    /// otherwise write the same count and the second heart arrive silent.
    static func saveNudgeRecord(_ record: CKRecord, in database: CKDatabase) async throws -> CKRecord {
        let operation = nudgeOperation(record)
        return try await withCheckedThrowingContinuation { continuation in
            attachNudge(operation, recordID: record.recordID) { continuation.resume(with: $0) }
            database.add(operation)
        }
    }

    static func nudgeOperation(_ record: CKRecord) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.configuration.isLongLived = true
        operation.configuration.qualityOfService = .userInitiated
        return operation
    }

    static func attachNudge(_ operation: CKModifyRecordsOperation,
                            recordID: CKRecord.ID,
                            completion: @escaping @Sendable (Result<CKRecord, Error>) -> Void) {
        let saved = SavedNudge()
        operation.perRecordSaveBlock = { id, result in
            if id == recordID { saved.set(result) }
        }
        operation.modifyRecordsResultBlock = { result in
            switch (saved.get(), result) {
            case (let own?, _): completion(own)
            case (nil, .failure(let error)): completion(.failure(error))
            case (nil, .success): completion(.failure(SyncError.saveUnconfirmed))
            }
        }
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// Our nudge record arrived in a delta (another device of ours saved it):
    /// the cache follows, so the next tap's save doesn't start with a conflict.
    func cacheNudgeRecord(_ record: CKRecord) async {
        let count = min(max(record[Field.count] as? Int ?? 0, 0), AppConfig.nudgeCountCeiling)
        await MainActor.run {
            SharedStore.shared.nudgeRecordCache = .init(systemFields: Self.systemFields(of: record), count: count)
        }
    }

    private final class SavedNudge: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<CKRecord, Error>?
        func set(_ result: Result<CKRecord, Error>) { lock.withLock { self.result = result } }
        func get() -> Result<CKRecord, Error>? { lock.withLock { result } }
    }
}
