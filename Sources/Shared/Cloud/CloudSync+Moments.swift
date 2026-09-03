import CloudKit
import Foundation
import os

// Moment records and their media assets: send, on-demand download, record
// parsing, change-token coding.
extension CloudSync {
    /// Writes a new moment record. One record per moment, kept indefinitely —
    /// that's what makes the history durable and recoverable.
    func send(_ moment: Moment) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)

        let recordID = CKRecord.ID(recordName: pairing.role.momentRecordName(id: moment.id),
                                   zoneID: zoneID(for: pairing))

        let record = CKRecord(recordType: RecordType.moment, recordID: recordID)
        record[Field.momentID] = moment.id as CKRecordValue
        record[Field.kind] = moment.kind.rawValue as CKRecordValue
        record[Field.sentAt] = moment.sentAt as CKRecordValue
        record.encryptedValues[Field.caption] = moment.caption
        record.encryptedValues[Field.senderName] = moment.senderName

        let store = MomentStore.shared
        if moment.isVoice {
            guard let audioURL = store.audioURL(for: moment.id),
                  FileManager.default.fileExists(atPath: audioURL.path) else {
                throw MomentStoreError.audioMissing
            }
            record[Field.audio] = CKAsset(fileURL: audioURL)
            record[Field.duration] = moment.duration as CKRecordValue
            record.encryptedValues[Field.waveform] = moment.waveform
        } else {
            guard let fullURL = store.imageURL(for: moment.id),
                  let thumbURL = store.thumbURL(for: moment.id) else {
                throw MomentStoreError.containerUnavailable
            }
            record[Field.image] = CKAsset(fileURL: fullURL)
            record[Field.thumb] = CKAsset(fileURL: thumbURL)
        }

        try await withZoneRecovery(pairing) {
            _ = try await database.modifyRecords(saving: [record],
                                                 deleting: [],
                                                 savePolicy: .allKeys)
        }
    }

    static func logEntry(from record: CKRecord,
                                 mineRole: PairRole,
                                 theirsRole: PairRole) -> StatusHistoryEntry? {
        let name = record.recordID.recordName
        let fromMe: Bool
        let named: Date
        if let date = mineRole.statusLogDate(fromRecordName: name) {
            fromMe = true
            named = date
        } else if let date = theirsRole.statusLogDate(fromRecordName: name) {
            fromMe = false
            named = date
        } else {
            return nil
        }
        // Dated from the *name*, not the field: the name is what dedups against
        // the `Status` record's own entry, and the field carries the same value.
        return StatusHistoryEntry(
            emoji: record.encryptedValues[Field.emoji] as? String ?? "💭",
            message: record.encryptedValues[Field.message] as? String ?? "",
            isCelebration: (record.encryptedValues[Field.isCelebration] as? Int).map { $0 != 0 } ?? false,
            at: named,
            fromMe: fromMe
        )
    }

    /// Pulls the media file(s) for one history entry that isn't cached locally.
    /// Called by the gallery when you scroll back past the cache window.
    func fetchMedia(for moment: Moment) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        try await downloadMedia(for: moment, pairing: pairing, in: database)
    }

    func downloadMedia(for moment: Moment,
                               pairing: PairingInfo,
                               in database: CKDatabase) async throws {
        let role = moment.fromMe ? pairing.role : pairing.role.other
        let recordID = CKRecord.ID(recordName: role.momentRecordName(id: moment.id),
                                   zoneID: zoneID(for: pairing))
        guard let record = try await fetchRecord(recordID, in: database) else { return }

        let store = MomentStore.shared
        if moment.isVoice {
            try Self.copyAsset(record[Field.audio] as? CKAsset, to: store.audioURL(for: moment.id))
        } else {
            try Self.copyAsset(record[Field.image] as? CKAsset, to: store.imageURL(for: moment.id))
            try Self.copyAsset(record[Field.thumb] as? CKAsset, to: store.thumbURL(for: moment.id))
        }
    }

    static func moment(from record: CKRecord,
                               mineRole: PairRole,
                               theirsRole: PairRole) -> Moment? {
        let name = record.recordID.recordName
        let fromMe: Bool
        if mineRole.momentID(fromRecordName: name) != nil {
            fromMe = true
        } else if theirsRole.momentID(fromRecordName: name) != nil {
            fromMe = false
        } else {
            return nil
        }

        guard let id = record[Field.momentID] as? String,
              isSafeMomentID(id),
              let kindRaw = record[Field.kind] as? String,
              let kind = Moment.Kind(rawValue: kindRaw) else { return nil }

        return Moment(
            id: id,
            kind: kind,
            caption: record.encryptedValues[Field.caption] as? String ?? "",
            senderName: record.encryptedValues[Field.senderName] as? String ?? "",
            sentAt: record[Field.sentAt] as? Date ?? record.modificationDate ?? Date(),
            fromMe: fromMe,
            duration: record[Field.duration] as? Double ?? 0,
            waveform: record.encryptedValues[Field.waveform] as? [Double] ?? []
        )
    }

    /// Moment ids come from the partner's device and are interpolated into App
    /// Group file paths; a modified client sending `../…` must not escape `Moments/`.
    static func isSafeMomentID(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= 64
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("..")
            && id != "."
    }

    static func copyAsset(_ asset: CKAsset?, to destination: URL?) throws {
        guard let source = asset?.fileURL, let destination else { return }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func decodeToken(_ data: Data?) -> CKServerChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
