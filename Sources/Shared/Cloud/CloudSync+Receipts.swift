import CloudKit
import Foundation
import os

// Read receipts: one encrypted seen-map plus the status receipt per side.
extension CloudSync {
    /// Writes this device's seen-map and status receipt, overwriting the whole
    /// record. An empty map and `nil` are a retraction — receipts were turned off.
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.receiptRecordName,
                                   zoneID: zoneID(for: pairing))

        try await withZoneRecovery(pairing) {
            do {
                try await saveReceipts(seen, statusSeen: statusSeen, to: recordID, in: database)
            } catch let error as CKError where error.code == .serverRecordChanged {
                log.notice("Receipt conflict, retrying against server record.")
                try await saveReceipts(seen, statusSeen: statusSeen, to: recordID, in: database)
            }
        }
    }

    func saveReceipts(_ seen: [String: Date],
                              statusSeen: StatusSeen?,
                              to recordID: CKRecord.ID,
                              in database: CKDatabase) async throws {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.receipt, recordID: recordID)
        // 0 encodes "seen, time unknown" (.distantPast) — see Moment.seenAt.
        let raw = seen.mapValues { $0 == .distantPast ? 0 : $0.timeIntervalSince1970 }
        record.encryptedValues[Field.seenMap] = try JSONEncoder().encode(raw)
        // `nil` removes the fields — a retraction, like the empty map.
        record.encryptedValues[Field.statusSeenAt] = statusSeen?.seenAt
        record.encryptedValues[Field.statusSeenFor] = statusSeen?.statusUpdatedAt
        record[Field.updatedAt] = Date() as CKRecordValue
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
    }

    static func statusSeen(from record: CKRecord) -> StatusSeen? {
        guard let seenAt = record.encryptedValues[Field.statusSeenAt] as? Date,
              let statusUpdatedAt = record.encryptedValues[Field.statusSeenFor] as? Date else {
            return nil
        }
        return StatusSeen(statusUpdatedAt: statusUpdatedAt, seenAt: seenAt)
    }

    static func receiptMap(from record: CKRecord) -> [String: Date] {
        guard let data = record.encryptedValues[Field.seenMap] as? Data,
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return raw.reduce(into: [:]) { result, item in
            guard isSafeMomentID(item.key) else { return }
            result[item.key] = item.value <= 0 ? .distantPast : Date(timeIntervalSince1970: item.value)
        }
    }
}
