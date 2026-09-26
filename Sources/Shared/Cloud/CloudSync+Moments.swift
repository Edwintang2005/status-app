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
            let result = try await database.modifyRecords(saving: [record],
                                                          deleting: [],
                                                          savePolicy: .allKeys)
            try Self.confirmSaved(result, recordID)
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
        // No placeholder: `StatusHistoryLog` keeps the first entry it sees for a
        // timestamp, so a 💭 written here would outlive the readable copy.
        guard let emoji = record.encryptedValues[Field.emoji] as? String else { return nil }
        // Dated from the *name*, not the field: the name is what dedups against
        // the `Status` record's own entry, and the field carries the same value.
        // Capped the same way as that entry, so a skewed clock can't pin it.
        return StatusHistoryEntry(
            emoji: String(emoji.prefix(AppConfig.statusEmojiMaxLength)),
            message: String((record.encryptedValues[Field.message] as? String ?? "").prefix(AppConfig.statusMessageMaxLength)),
            isCelebration: (record.encryptedValues[Field.isCelebration] as? Int).map { $0 != 0 } ?? false,
            at: TrustedTime.plausible(named, serverTime: record.modificationDate),
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

    /// The thumbnail alone, by `desiredKeys` so the full-size asset never
    /// leaves the server for a tile that only needs the small one.
    func fetchThumbnail(for moment: Moment) async throws {
        guard !moment.isVoice else { return }
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let role = moment.fromMe ? pairing.role : pairing.role.other
        let recordID = CKRecord.ID(recordName: role.momentRecordName(id: moment.id),
                                   zoneID: zoneID(for: pairing))
        let results = try await database.records(for: [recordID], desiredKeys: [Field.thumb])
        guard case .success(let record)? = results[recordID] else { return }
        try Self.copyAsset(record[Field.thumb] as? CKAsset, to: MomentStore.shared.thumbURL(for: moment.id))
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

        // Everything below is sanitised on the way in: a NaN in the waveform
        // made the whole index unsavable, a negative-year date unloadable.
        let sentAt = (record[Field.sentAt] as? Date).flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
            ?? record.modificationDate ?? Date()
        let waveform = (record.encryptedValues[Field.waveform] as? [Double] ?? [])
            .prefix(AppConfig.voiceWaveformSampleCount * 4)
            .map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        return Moment(
            id: id,
            kind: kind,
            caption: String((record.encryptedValues[Field.caption] as? String ?? "").prefix(AppConfig.captionMaxLength)),
            senderName: String((record.encryptedValues[Field.senderName] as? String ?? "").prefix(AppConfig.displayNameMaxLength)),
            sentAt: TrustedTime.plausible(sentAt, serverTime: record.modificationDate),
            fromMe: fromMe,
            // The partner's number: `Int(duration)` in the label traps on non-finite.
            duration: (record[Field.duration] as? Double).flatMap { $0.isFinite && $0 >= 0 ? min($0, 24 * 60 * 60) : nil } ?? 0,
            waveform: Array(waveform)
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

    /// Copy to a sibling temp name, then rename: a process killed mid-copy (a
    /// widget past its budget, the extension on deadline) must not leave a
    /// truncated file that `MomentStore.hasMedia` would take for the real one.
    static func copyAsset(_ asset: CKAsset?, to destination: URL?) throws {
        guard let source = asset?.fileURL, let destination else { return }
        let staging = destination.appendingPathExtension("part")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
    }

    static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func decodeToken(_ data: Data?) -> CKServerChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
