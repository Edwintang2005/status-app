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
        let mine = changes.records.map(\.recordID).filter {
            ZoneClearPlan.deletes($0.recordName, role: role, scope: .unlink)
        }
        guard !mine.isEmpty else { return }

        // Batched: hundreds of deletions in one modify is a `limitExceeded`.
        for batch in mine.chunked(into: 200) {
            let result = try await database.modifyRecords(saving: [], deleting: batch)
            // Leaving one behind sits in the ex's iCloud; "already gone" is fine.
            for id in batch {
                do { try Self.confirmDeleted(result, id) }
                catch let error as CKError where Self.isUnknownItem(error) {}
            }
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
        try Self.confirmDeleted(try await database.modifyRecords(saving: [], deleting: [shareID]), shareID)
    }

    /// Whether an error means "it isn't there any more", bare or for every item
    /// of a batch — one real error among them must still surface.
    static func isAlreadyGone(_ error: CKError) -> Bool {
        error.isEvery(of: [.unknownItem, .zoneNotFound, .userDeletedZone])
    }

    /// "That record doesn't exist" only, without the zone-gone codes `isAlreadyGone` accepts.
    static func isUnknownItem(_ error: CKError) -> Bool {
        error.isEvery(of: [.unknownItem])
    }

    /// A change-tag conflict, bare or on any item.
    static func isServerRecordChanged(_ error: Error) -> Bool {
        (error as? CKError)?.isAny(.serverRecordChanged) ?? false
    }

    /// Runs a fetch-modify-save until it lands without a change-tag conflict:
    /// each attempt refetches, so it saves on top of whatever raced it. Three
    /// covers overlapping publishes and a second heart tap on slow signal.
    func retryingConflicts<T>(_ what: String, _ save: () async throws -> T) async throws -> T {
        for attempt in 1..<3 {
            do {
                return try await save()
            } catch where Self.isServerRecordChanged(error) {
                log.notice("\(what, privacy: .public) conflict (attempt \(attempt)); retrying on the server copy.")
                try? await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
        return try await save()
    }

    /// Token expiry is zone-scoped, so it usually arrives inside `.partialFailure`.
    static func isTokenExpired(_ error: CKError) -> Bool {
        error.isAny(.changeTokenExpired)
    }
}

extension CKError {
    /// The per-item errors of a `.partialFailure`; empty for any other code.
    var itemErrors: [CKError] {
        guard code == .partialFailure else { return [] }
        return partialErrorsByItemID?.values.compactMap { $0 as? CKError } ?? []
    }

    /// One of `codes` bare, or every item's code is.
    func isEvery(of codes: Set<CKError.Code>) -> Bool {
        if codes.contains(code) { return true }
        let items = itemErrors.map(\.code)
        return !items.isEmpty && items.allSatisfy(codes.contains)
    }

    /// `code` bare, or on any item.
    func isAny(_ code: CKError.Code) -> Bool {
        self.code == code || itemErrors.contains { $0.code == code }
    }
}
