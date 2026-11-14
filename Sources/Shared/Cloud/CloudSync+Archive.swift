import CloudKit
import Foundation

// The memories archive's look at the whole zone. Read-only: no change token is
// read or written and nothing is filed, so it can't disturb a refresh.
extension CloudSync {
    func archiveZone() async throws -> ArchiveContents.Zone {
        let pairing = try await requirePairing()
        let changes = try await fetchZoneChanges(zone: zoneID(for: pairing),
                                                 in: database(for: pairing),
                                                 since: nil)
        let hidden = await MainActor.run { self.stores.shared.hiddenMomentIDs }
        let parsed = ParsedDelta.parse(records: changes.records, deletedIDs: [],
                                       mineRole: pairing.role, hidden: hidden)
        return ArchiveContents.Zone(moments: parsed.moments,
                                    statuses: parsed.logEntries,
                                    unreadable: parsed.unreadable.count)
    }

    /// One by-ID request for the lot, asking only for the file each needs — the
    /// full picture or the recording, never the thumbnail. A record iCloud no
    /// longer has is `notFound`; one without its file, `gone`.
    func fetchArchiveMedia(_ moments: [Moment], to destinations: [String: URL]) async throws -> [String: ArchiveMedia] {
        let pairing = try await requirePairing()
        let byRecord = recordIDs(for: moments, pairing: pairing)
        guard !byRecord.isEmpty else { return [:] }
        let fetched = try await cloudDatabase(for: pairing)
            .fetchRecords(Array(byRecord.keys), desiredKeys: [Field.image, .audio].map(\.rawValue))
        // Abandoned at its deadline: nothing is written after the caller moved on.
        try Task.checkCancellation()
        var results: [String: ArchiveMedia] = [:]
        for (recordID, result) in fetched {
            guard let moment = byRecord[recordID] else { continue }
            switch result {
            case .success(let record):
                guard let asset = record[moment.isVoice ? Field.audio : Field.image] as? CKAsset,
                      asset.fileURL != nil else {
                    results[moment.id] = .gone
                    continue
                }
                do {
                    try Self.copyAsset(asset, to: destinations[moment.id])
                    results[moment.id] = .saved
                } catch {
                    log.error("Couldn't save \(moment.id) for the archive: \(error.localizedDescription)")
                    results[moment.id] = .failed(retryAt: nil)
                }
            case .failure(let error):
                results[moment.id] = Self.archiveMedia(after: error)
            }
        }
        return results
    }

    static func archiveMedia(after error: Error) -> ArchiveMedia {
        if (error as? CKError)?.code == .unknownItem { return .notFound }
        if case .throttled(let until) = SendFailure(error) { return .failed(retryAt: until) }
        return .failed(retryAt: nil)
    }
}
