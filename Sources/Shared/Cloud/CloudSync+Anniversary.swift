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
            do {
                try await saveAnniversary(anniversary, to: recordID, in: database)
            } catch let error as CKError where error.code == .serverRecordChanged {
                log.notice("Anniversary conflict, retrying against server record.")
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
        let result = try await database.modifyRecords(saving: [record],
                                                      deleting: [],
                                                      savePolicy: .changedKeys)
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

    static func anniversaryRequestDate(from record: CKRecord) -> Date? {
        guard let date = record.encryptedValues[Field.requestedAt] as? Date else { return nil }
        // Whole seconds, like every persisted date: compared against its own stored copy.
        return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func anniversary(from record: CKRecord) -> Anniversary? {
        guard let startsAt = record.encryptedValues[Field.startsAt] as? Date else { return nil }
        let zone = record.encryptedValues[Field.timeZone] as? String
        return Anniversary(startsAt: startsAt, timeZoneID: zone ?? TimeZone.current.identifier)
    }
}
