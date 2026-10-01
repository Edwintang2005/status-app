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
        let hidden = await MainActor.run { SharedStore.shared.hiddenMomentIDs }
        let parsed = ParsedDelta.parse(records: changes.records, deletedIDs: [],
                                       mineRole: pairing.role, hidden: hidden)
        return ArchiveContents.Zone(moments: parsed.moments,
                                    statuses: parsed.logEntries,
                                    unreadable: parsed.unreadable.count)
    }
}
