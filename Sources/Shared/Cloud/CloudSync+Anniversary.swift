import CloudKit
import Foundation
import os

// The pair's anniversary: one record, owner-written, read by both on any refresh.
extension CloudSync {
    /// Writes (or, with `nil`, deletes) the pair's `Anniversary` record. Owner
    /// only — the UI gates it, and this refuses too, so a participant build
    /// can never overwrite the owner's date. A delete can't be made conditional
    /// in CloudKit; a late one is caught on the way back (`RefreshDelta`).
    func publishAnniversary(_ anniversary: Anniversary?, editedAt: Date?) async throws -> AnniversaryPublishOutcome {
        let pairing = try await requirePairing()
        guard pairing.role == .owner else { throw SyncError.notOwner }
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: Self.anniversaryRecordName,
                                   zoneID: zoneID(for: pairing))

        return try await withZoneRecovery(pairing) {
            guard let anniversary else {
                let existing = try await fetchRecord(recordID, in: database)
                if let newer = try Self.newerEdit(existing, than: editedAt) { return newer }
                guard existing != nil else { return .done(foundRecord: false) }
                do {
                    let result = try await database.waited { try await $0.modifyRecords(saving: [], deleting: [recordID]) }
                    try Self.confirmDeleted(result, recordID)
                } catch let error as CKError where Self.isUnknownItem(error) {
                    // Already cleared: the outcome is the same.
                }
                return .done(foundRecord: true)
            }
            return try await retryingConflicts("Anniversary") {
                try await saveAnniversary(anniversary, editedAt: editedAt, to: recordID, in: database)
            }
        }
    }

    /// Re-judged on every attempt, the conflict retry's too: a save timed out
    /// and landing late, or retried after a newer edit beat it, never overwrites
    /// that edit — the record's `updatedAt` is when its date was edited.
    func saveAnniversary(_ anniversary: Anniversary,
                         editedAt: Date?,
                         to recordID: CKRecord.ID,
                         in database: CKDatabase) async throws -> AnniversaryPublishOutcome {
        let existing = try await fetchRecord(recordID, in: database)
        if let newer = try Self.newerEdit(existing, than: editedAt) { return newer }
        let record = existing ?? CKRecord(recordType: RecordType.anniversary, recordID: recordID)
        record.encryptedValues[Field.startsAt] = anniversary.startsAt
        record.encryptedValues[Field.timeZone] = anniversary.timeZoneID
        record[Field.updatedAt] = (editedAt ?? Date()) as CKRecordValue
        // Change-tag checked, so the conflict retry in `publishAnniversary` can fire.
        let result = try await database.waited { try await $0.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .ifServerRecordUnchanged) }
        try Self.confirmSaved(result, recordID)
        return .done(foundRecord: existing != nil)
    }

    /// The zone's copy, when it was edited after `editedAt`: ours stands aside and
    /// takes it. Its stamp is capped by server time (invariant 23), so a skewed or
    /// forged one can't hold every later edit off; unreadable, it's judged later.
    static func newerEdit(_ record: CKRecord?, than editedAt: Date?) throws -> AnniversaryPublishOutcome? {
        guard let record, let held = heldStamp(record), let editedAt, held > editedAt else { return nil }
        guard let anniversary = anniversary(from: record) else { throw SyncError.saveUnconfirmed }
        return .superseded(anniversary, editedAt: held)
    }

    /// When the record's date was edited — an unstamped edit (`nil`) always writes.
    static func heldStamp(_ record: CKRecord?) -> Date? {
        guard let record, let held = record[Field.updatedAt] as? Date else { return nil }
        return TrustedTime.plausible(held, serverTime: record.modificationDate)
    }

    /// Participant only: asks the owner to set the date. One fixed record, so a
    /// second ask overwrites the first; the owner's device shows it once per ask.
    func publishAnniversaryRequest(at date: Date) async throws {
        let pairing = try await requirePairing()
        guard pairing.role == .participant else { throw SyncError.notParticipant }
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: Self.anniversaryRequestRecordName,
                                   zoneID: zoneID(for: pairing))
        try await withZoneRecovery(pairing) {
            // Every field set and `.allKeys` overwrites: no fetch first.
            let record = CKRecord(recordType: RecordType.anniversaryRequest, recordID: recordID)
            record.encryptedValues[Field.requestedAt] = date
            record[Field.updatedAt] = Date() as CKRecordValue
            let result = try await database.waited { try await $0.modifyRecords(saving: [record],
                                                          deleting: [],
                                                          savePolicy: .allKeys) }
            try Self.confirmSaved(result, recordID)
        }
    }

    /// Bounded (invariant 23) and whole seconds: compared against its own stored copy.
    static func anniversaryRequestDate(from record: CKRecord) -> Date? {
        guard let date = record.encryptedValues[Field.requestedAt] as? Date,
              date.timeIntervalSince1970.isFinite else { return nil }
        return TrustedTime.plausible(date, serverTime: record.modificationDate)
    }

    /// The date may predate 1970, so it has its own floor (`Anniversary.earliest`)
    /// rather than `TrustedTime`'s; the ceiling is the same.
    static func anniversary(from record: CKRecord, now: Date = Date()) -> Anniversary? {
        guard let startsAt = record.encryptedValues[Field.startsAt] as? Date,
              startsAt.timeIntervalSince1970.isFinite else { return nil }
        let ceiling = (record.modificationDate ?? now).addingTimeInterval(AppConfig.clockSkewAllowance)
        let bounded = min(max(startsAt, Anniversary.earliest), ceiling)
        let zone = (record.encryptedValues[Field.timeZone] as? String).map { String($0.prefix(64)) }
        return Anniversary(startsAt: bounded, timeZoneID: zone ?? TimeZone.current.identifier)
    }
}
