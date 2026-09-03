import CloudKit
import Foundation
import os

// Ending the link, cloud-first (CLAUDE.md invariant 8), and the CKError
// classification helpers the whole actor shares.
extension CloudSync {
    /// Ends the link from this side, cloud-first. Owner: deletes the zone, removing
    /// everything for both people. Participant: our own records must be deleted
    /// *before* leaving the share, or they'd sit in the ex's iCloud after we'd gone.
    func unpair() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            return
        }
        // Under another account the owner's zone ID resolves to *their* CoupleZone —
        // deleting it would end a stranger's pairing.
        guard await isPairingAccount(pairing) else { throw SyncError.differentAccount }
        let database = self.database(for: pairing)
        let zone = zoneID(for: pairing)

        // Best effort: failing the unlink over a stale subscription would be perverse.
        _ = try? await database.modifySubscriptions(saving: [], deleting: SubscriptionID.all)

        do {
            switch pairing.role {
            case .owner:
                _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
            case .participant:
                try await deleteOwnRecords(role: pairing.role, in: zone, database: database)
                try await leaveShare(zone: zone, database: database)
            }
        } catch let error as CKError where Self.isAlreadyGone(error) {
            // "Gone" is only good news under the pairing's account; under a different
            // one the zone merely *looks* gone while the data sits intact.
            guard await isPairingAccount(pairing) else {
                throw SyncError.differentAccount
            }
            // They got there first. Nothing to delete is the outcome we wanted.
            log.notice("Shared zone already gone; unlink is a no-op.")
        }
    }

    /// Deletes every record belonging to our own role, via a full change fetch —
    /// moment records have UUID names, so there's nothing to query by name.
    func deleteOwnRecords(role: PairRole,
                                  in zone: CKRecordZone.ID,
                                  database: CKDatabase) async throws {
        let changes = try await fetchZoneChanges(zone: zone, in: database, since: nil)
        let mine = changes.records.map(\.recordID).filter { id in
            let name = id.recordName
            return name == role.statusRecordName
                || name == role.nudgeRecordName
                || name == role.receiptRecordName
                || role.momentID(fromRecordName: name) != nil
                || role.statusLogDate(fromRecordName: name) != nil
        }
        guard !mine.isEmpty else { return }

        // Batched: hundreds of deletions in one modify is a `limitExceeded`.
        for start in stride(from: 0, to: mine.count, by: 200) {
            let batch = Array(mine[start..<min(start + 200, mine.count)])
            _ = try await database.modifyRecords(saving: [], deleting: batch)
        }
        log.notice("Deleted \(mine.count) of our own records before leaving the share.")
    }

    /// Removes this account from the share, which is what makes the zone
    /// disappear from our shared database.
    func leaveShare(zone: CKRecordZone.ID, database: CKDatabase) async throws {
        let zones = try await database.recordZones(for: [zone])
        guard case .success(let record)? = zones[zone],
              let shareID = record.share?.recordID else {
            // No share reference — drop the zone from our shared database instead.
            _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
            return
        }
        _ = try await database.modifyRecords(saving: [], deleting: [shareID])
    }

    /// Whether an error means "it isn't there any more". Partial failures are
    /// unwrapped because a batch delete reports per-item errors.
    static func isAlreadyGone(_ error: CKError) -> Bool {
        let gone: Set<CKError.Code> = [.unknownItem, .zoneNotFound, .userDeletedZone]
        if gone.contains(error.code) { return true }
        guard error.code == .partialFailure,
              let partials = error.partialErrorsByItemID?.values else { return false }
        // Every failure must be a "gone" one; a real error must still surface.
        let codes = partials.compactMap { ($0 as? CKError)?.code }
        return !codes.isEmpty && codes.allSatisfy(gone.contains)
    }

    /// "That record doesn't exist" only — bare or per-item — without the
    /// zone-gone codes `isAlreadyGone` also accepts.
    static func isUnknownItem(_ error: CKError) -> Bool {
        if error.code == .unknownItem { return true }
        guard error.code == .partialFailure,
              let partials = error.partialErrorsByItemID?.values else { return false }
        let codes = partials.compactMap { ($0 as? CKError)?.code }
        return !codes.isEmpty && codes.allSatisfy { $0 == .unknownItem }
    }

    /// Token expiry arrives either bare or wrapped in `.partialFailure` (zone-scoped).
    static func isTokenExpired(_ error: CKError) -> Bool {
        if error.code == .changeTokenExpired { return true }
        guard error.code == .partialFailure,
              let partials = error.partialErrorsByItemID?.values else { return false }
        return partials.contains { ($0 as? CKError)?.code == .changeTokenExpired }
    }
}
