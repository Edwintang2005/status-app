import CloudKit
import Foundation
import os

// The pair's anniversary: one record, owner-written, read by both on any refresh.
extension CloudSync {
    /// Writes (or, with `nil`, deletes) the pair's `Anniversary` record. Owner
    /// only — the UI gates it, and this refuses too, so a participant build
    /// can never overwrite the owner's date.
    func publishAnniversary(_ anniversary: Anniversary?) async throws {
        let pairing = try await requirePairing()
        guard pairing.role == .owner else { throw SyncError.notOwner }
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: Self.anniversaryRecordName,
                                   zoneID: zoneID(for: pairing))

        try await withZoneRecovery(pairing) {
            guard let anniversary else {
                do {
                    let result = try await database.modifyRecords(saving: [], deleting: [recordID])
                    try Self.confirmDeleted(result, recordID)
                } catch let error as CKError where Self.isUnknownItem(error) {
                    // Never set, or already cleared: the outcome is the same.
                }
                return
            }
            try await retryingConflicts("Anniversary") {
                try await saveAnniversary(anniversary, to: recordID, in: database)
            }
        }
    }

    func saveAnniversary(_ anniversary: Anniversary,
                         to recordID: CKRecord.ID,
                         in database: CKDatabase) async throws {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.anniversary, recordID: recordID)
        record.encryptedValues[Field.startsAt] = anniversary.startsAt
        record.encryptedValues[Field.timeZone] = anniversary.timeZoneID
        record[Field.updatedAt] = Date() as CKRecordValue
        // Change-tag checked, so the conflict retry in `publishAnniversary` can fire.
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .ifServerRecordUnchanged)
        try Self.confirmSaved(result, recordID)
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
            let record = try await fetchRecord(recordID, in: database)
                ?? CKRecord(recordType: RecordType.anniversaryRequest, recordID: recordID)
            record.encryptedValues[Field.requestedAt] = date
            record[Field.updatedAt] = Date() as CKRecordValue
            let result = try await database.modifyRecords(saving: [record],
                                                          deleting: [],
                                                          savePolicy: .allKeys)
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
