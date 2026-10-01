import CloudKit
import Foundation
import os

// The fresh start's writes: our own `FreshStart` record, and — once both sides
// committed — our own history out of the zone. The app calls these; the
// extensions only read the records (`ParsedDelta`) and never delete.
extension CloudSync {
    /// Applies `intent` to our record as the server holds it now, under a
    /// change-tag check, so a withdraw and a commit from two of our devices
    /// can't both land (`FreshStartPolicy.transition`).
    func publishFreshStart(_ intent: FreshStartIntent) async throws -> FreshStartPublishResult {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.freshStartRecordName,
                                   zoneID: zoneID(for: pairing))
        let partnerID = CKRecord.ID(recordName: pairing.role.other.freshStartRecordName,
                                    zoneID: recordID.zoneID)
        let names = myRecordNames(pairing)
        return try await withZoneRecovery(pairing) {
            try await retryingConflicts("FreshStart") {
                // Only an ask looks at theirs: it mustn't replace a yes that still counts.
                var theirs: FreshStartRecord?
                if intent == .ask, let partner = try await fetchRecord(partnerID, in: database), Self.isReadable(partner) {
                    theirs = Self.freshStart(from: partner, savedAt: partner.modificationDate)
                }
                return try await saveFreshStart(intent, to: recordID, partner: theirs, names: names, in: database)
            }
        }
    }

    func saveFreshStart(_ intent: FreshStartIntent,
                        to recordID: CKRecord.ID,
                        partner: FreshStartRecord?,
                        names: Set<String>,
                        in database: CKDatabase) async throws -> FreshStartPublishResult {
        let server = try await fetchRecord(recordID, in: database)
        // The app holds the share's keys; a copy it can't read is no basis for a write.
        if let server, !Self.isReadable(server) { throw SyncError.saveUnconfirmed }
        // A copy another account wrote is no consent of ours: overwritten, never built on.
        let current = server.flatMap { record in
            Self.isForeign(record, names: names) ? nil : Self.freshStart(from: record, savedAt: record.modificationDate)
        }
        switch FreshStartPolicy.transition(intent, from: current, partner: partner) {
        case .unchanged(let record):
            return .saved(record)
        case .refused(let record):
            log.notice("Fresh start \(String(describing: intent), privacy: .public) refused: the record moved on.")
            return .refused(record)
        case .write(let target):
            let record = server ?? CKRecord(recordType: RecordType.freshStart, recordID: recordID)
            record.encryptedValues[Field.stage] = target.stage.rawValue
            record.encryptedValues[Field.epoch] = target.stage == .asking ? nil : target.epoch
            record.encryptedValues[Field.clearedBefore] = target.clearedBefore
            let result = try await database.modifyRecords(saving: [record],
                                                          deleting: [],
                                                          savePolicy: .ifServerRecordUnchanged)
            let saved = try Self.confirmSaved(result, recordID)
            var written = target
            // An ask's epoch is the server's own time for this save.
            if target.stage == .asking {
                guard let savedAt = saved.modificationDate else { throw SyncError.saveUnconfirmed }
                written.epoch = TrustedTime.plausible(savedAt, serverTime: savedAt)
            }
            return .saved(written)
        }
    }

    /// Deletes our own history created before `epoch` (`FreshStartPolicy.zonePlan`)
    /// after re-reading both `FreshStart` records from the server: nothing goes
    /// on the strength of this phone's last fold. Idempotent — a pass killed
    /// halfway re-runs from the top. Returns the zone's classification for the
    /// local clear, which the caller performs only after this succeeds.
    func clearHistory(before epoch: Date, keepingStatusLogAt keep: Date?) async throws -> FreshStartPolicy.Zone {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let zone = zoneID(for: pairing)
        let changes = try await withZoneRecovery(pairing) {
            try await fetchZoneChanges(zone: zone, in: database, since: nil)
        }

        let names = myRecordNames(pairing)
        var mine: FreshStartRecord?
        var theirs: FreshStartRecord?
        for record in changes.records where record.recordType == RecordType.freshStart && Self.isReadable(record) {
            let parsed = Self.freshStart(from: record, savedAt: record.modificationDate)
            if record.recordID.recordName == pairing.role.freshStartRecordName, !Self.isForeign(record, names: names) {
                mine = parsed
            } else if record.recordID.recordName == pairing.role.other.freshStartRecordName {
                theirs = parsed
            }
        }
        guard FreshStartPolicy.isCommitted(epoch, mine: mine, theirs: theirs) else {
            throw SyncError.freshStartNotAgreed
        }

        let items = changes.records.map {
            FreshStartPolicy.ZoneItem(recordName: $0.recordID.recordName,
                                      createdAt: $0.creationDate ?? $0.modificationDate)
        }
        let plan = FreshStartPolicy.zonePlan(items, role: pairing.role, epoch: epoch, keepingStatusLogAt: keep)
        let ids = plan.deletions.map { CKRecord.ID(recordName: $0, zoneID: zone) }

        // Non-atomic and confirmed per record (invariant 22): one failure mustn't
        // undo the rest, and a failed one is retried on the next pass.
        var failure: Error?
        for start in stride(from: 0, to: ids.count, by: 200) {
            // An unlink landed mid-clear: what's left is the unlink's to delete.
            guard await MainActor.run(body: { SharedStore.shared.pairing?.sameZone(as: pairing) == true }) else {
                throw SyncError.notPaired
            }
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            let result = try await withZoneRecovery(pairing) {
                try await database.modifyRecords(saving: [], deleting: batch, atomically: false)
            }
            for id in batch {
                do {
                    try Self.confirmDeleted(result, id)
                } catch let error as CKError where Self.isUnknownItem(error) {
                    // Another of our devices, or an earlier pass, got there first.
                } catch {
                    failure = failure ?? error
                }
            }
        }
        if let failure { throw failure }
        log.notice("Fresh start: deleted \(ids.count) of our own history records.")
        return plan.zone
    }

    /// The names CloudKit may give this account as a record's author.
    func myRecordNames(_ pairing: PairingInfo) -> Set<String> {
        var names: Set<String> = [CKCurrentUserDefaultName]
        if let name = pairing.userRecordName { names.insert(name) }
        if let name = cachedUserRecordName?.name { names.insert(name) }
        return names
    }

    /// Only on positive proof, like `isPairingAccount`: an author that isn't us.
    static func isForeign(_ record: CKRecord, names: Set<String>) -> Bool {
        isForeign(author: record.lastModifiedUserRecordID?.recordName, names: names)
    }

    /// Without our own account's real name (#14: a lookup that failed at
    /// pairing) a real name proves nothing, and refusing our own record would
    /// wedge the clear for good — so nothing is judged.
    static func isForeign(author: String?, names: Set<String>) -> Bool {
        guard let author, names.contains(where: { $0 != CKCurrentUserDefaultName }) else { return false }
        return !names.contains(author)
    }

    /// `savedAt` is the record's server save time: an ask's epoch, and the cap
    /// on any date it names — an epoch names a past save, and a mark ahead of
    /// it would keep history out for good.
    static func freshStart(from record: CKRecord, savedAt: Date?) -> FreshStartRecord? {
        guard let raw = record.encryptedValues[Field.stage] as? Int else { return nil }
        let stage = FreshStartRecord.Stage(rawValue: raw) ?? .idle
        func capped(_ date: Date?) -> Date? {
            guard let date, date.timeIntervalSince1970.isFinite else { return nil }
            return TrustedTime.plausible(min(date, savedAt ?? date), serverTime: savedAt)
        }
        let epoch = stage == .asking
            ? savedAt.map { TrustedTime.plausible($0, serverTime: $0) }
            : capped(record.encryptedValues[Field.epoch] as? Date)
        return FreshStartRecord(stage: stage,
                                epoch: epoch,
                                clearedBefore: capped(record.encryptedValues[Field.clearedBefore] as? Date))
    }
}
