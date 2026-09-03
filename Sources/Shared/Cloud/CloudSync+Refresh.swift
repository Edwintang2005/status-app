import CloudKit
import Foundation
import os

// The change fetch and how a delta folds into local state. Records are applied
// before the token is persisted (CLAUDE.md invariant 2).
extension CloudSync {
    /// Pulls everything changed in the shared zone since last time. A change fetch,
    /// not queries: moments have UUID names, and a device with no stored token gets
    /// the entire zone back — which is how a reinstall recovers the full history.
    @discardableResult
    func refresh() async throws -> RefreshResult {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let zone = zoneID(for: pairing)
        let tokenKey = pairing.role == .owner ? "private" : "shared"

        var previous = await MainActor.run {
            Self.decodeToken(SharedStore.shared.changeToken(for: tokenKey))
        }

        let changes: ZoneChanges
        do {
            changes = try await fetchZoneChanges(zone: zone, in: database, since: previous)
        } catch let error as CKError where Self.isTokenExpired(error) {
            // Token expiry is zone-scoped, so it arrives wrapped in .partialFailure —
            // matching only the bare code left every refresh failing forever.
            log.notice("Change token expired, resyncing the whole zone.")
            previous = nil
            await MainActor.run { SharedStore.shared.setChangeToken(nil, for: tokenKey) }
            changes = try await fetchZoneChanges(zone: zone, in: database, since: nil)
        } catch let error as CKError where Self.isAlreadyGone(error) {
            // The other side unlinked, or the zone was never reachable.
            try await abandonMissingZone(pairing)
            throw SyncError.linkEnded
        }

        // Apply first, then advance the token: the other order can persist the token
        // without the records (the extension gets killed on a deadline), losing them
        // forever. Re-applying the same delta twice is tolerated everywhere here.
        let result = await apply(changes, pairing: pairing, database: database)

        if let token = changes.token {
            let encoded = Self.encodeToken(token)
            await MainActor.run {
                // An unlink mid-refresh cleared the tokens; writing this one back
                // would hand the next pairing a cursor into a zone that's gone.
                guard SharedStore.shared.pairing != nil else { return }
                SharedStore.shared.setChangeToken(encoded, for: tokenKey)
            }
        }

        // Automatic promote-and-close is OFF: promoting a link-joined (public)
        // participant evicted them from the share instead of converting them
        // (observed in Production, 2026-09: the atomic close+add landed, but the
        // partner survived as neither public nor private). Until a conversion
        // that provably preserves membership is found, closing is manual-only —
        // the Diagnostics button — so a failure is a deliberate, watched act
        // rather than a background loop that re-evicts the partner every refresh.
        // await closeInviteIfPartnerJoined(pairing)
        return result
    }

    /// A reference type on purpose: accumulating into a captured `var` struct is a
    /// data race to the compiler. CloudKit calls the blocks serially, so a box is enough.
    final class ZoneChanges: @unchecked Sendable {
        var records: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var token: CKServerChangeToken?
    }

    /// Assets are excluded via `desiredKeys` — a first sync would otherwise pull
    /// every photo and recording ever sent. Media is fetched separately, on demand.
    func fetchZoneChanges(zone: CKRecordZone.ID,
                                  in database: CKDatabase,
                                  since previous: CKServerChangeToken?) async throws -> ZoneChanges {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: previous,
            resultsLimit: nil,
            desiredKeys: [
                Field.emoji, Field.message, Field.displayName, Field.updatedAt,
                Field.isCelebration,
                Field.count,
                Field.momentID, Field.kind, Field.caption, Field.senderName, Field.sentAt,
                Field.duration, Field.waveform,
                Field.seenMap, Field.statusSeenAt, Field.statusSeenFor,
            ]
        )

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: configuration]
        )
        operation.fetchAllChanges = true

        let changes = ZoneChanges()
        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result { changes.records.append(record) }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            changes.deletedIDs.append(recordID)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            if case .success(let value) = result { changes.token = value.serverChangeToken }
        }

        // Without the cancellation handler the operation runs to completion regardless,
        // stalling the widget's getTimeline for the full network duration.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success: continuation.resume(returning: changes)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// Folds a batch of changed records into local state.
    func apply(_ changes: ZoneChanges,
                       pairing: PairingInfo,
                       database: CKDatabase) async -> RefreshResult {
        let mineRole = pairing.role
        let theirsRole = pairing.role.other

        var myStatus: CKRecord?
        var theirStatus: CKRecord?
        var myNudge: CKRecord?
        var theirNudge: CKRecord?
        var theirReceipts: CKRecord?
        var moments: [Moment] = []
        var logEntries: [StatusHistoryEntry] = []

        for record in changes.records {
            let name = record.recordID.recordName
            switch record.recordType {
            case RecordType.status:
                if name == mineRole.statusRecordName { myStatus = record }
                if name == theirsRole.statusRecordName { theirStatus = record }
            case RecordType.nudge:
                if name == mineRole.nudgeRecordName { myNudge = record }
                if name == theirsRole.nudgeRecordName { theirNudge = record }
            case RecordType.receipt:
                if name == theirsRole.receiptRecordName { theirReceipts = record }
            case RecordType.moment:
                if let moment = Self.moment(from: record, mineRole: mineRole, theirsRole: theirsRole) {
                    moments.append(moment)
                }
            case RecordType.statusLog:
                if let entry = Self.logEntry(from: record, mineRole: mineRole, theirsRole: theirsRole) {
                    logEntries.append(entry)
                }
            default:
                break
            }
        }

        // Captured before the insert below, so "new" can mean "not already
        // stored" — a full resync re-delivers the entire history, and reporting
        // it all as new re-announced already-seen moments.
        let alreadyKnown = MomentIndex.shared.knownIDs()

        // The partner deleting their own status record is how a participant
        // unlinks (they can't delete the owner's zone). Must not be ignored.
        var partnerErased = false
        var removedMoments = false
        var removedMyLogs: [Date] = []
        var removedTheirLogs: [Date] = []
        for recordID in changes.deletedIDs {
            let name = recordID.recordName
            if name == theirsRole.statusRecordName { partnerErased = true }
            if let id = mineRole.momentID(fromRecordName: name)
                ?? theirsRole.momentID(fromRecordName: name),
               Self.isSafeMomentID(id) {
                MomentIndex.shared.remove(id: id)
                MomentStore.shared.delete(id: id)
                removedMoments = true
            }
            if let date = mineRole.statusLogDate(fromRecordName: name) {
                removedMyLogs.append(date)
            } else if let date = theirsRole.statusLogDate(fromRecordName: name) {
                removedTheirLogs.append(date)
            }
        }
        // The cloud cap pruning the oldest entries, mirrored locally.
        StatusHistoryLog.shared.remove(fromMe: true, at: removedMyLogs)
        StatusHistoryLog.shared.remove(fromMe: false, at: removedTheirLogs)
        // A delete and a recreation can share one delta; the record that exists now wins.
        if theirStatus != nil { partnerErased = false }

        let store = SharedStore.shared
        let previousStatus = await MainActor.run { store.snapshot.theirs }

        // A status record and its nudge counter arrive independently; fold
        // each into what was already known.
        let mine = Self.payload(from: myStatus, nudge: myNudge,
                                existing: await MainActor.run { store.snapshot.mine })
        // Bound to a `let` before crossing actors: capturing the mutable flag
        // is a data race under strict concurrency.
        let erased = partnerErased
        let theirs = erased ? nil : Self.payload(from: theirStatus, nudge: theirNudge,
                                                 existing: previousStatus)

        await MainActor.run {
            _ = store.mutate(reloadWidgets: false) {
                // Checked *inside* the locked mutate: an unlink can land mid-refresh,
                // and writing this delta would resurrect the ex's status onto a wiped snapshot.
                guard store.pairing != nil else { return }
                if let mine {
                    // A status set offline is newer than the server copy; adopting the
                    // server's silently reverted it. Keep the newer local text and take
                    // only the server-owned nudge counter.
                    if mine.updatedAt >= ($0.mine?.updatedAt ?? .distantPast) {
                        $0.mine = mine
                    } else {
                        $0.mine?.nudgeCount = mine.nudgeCount
                        $0.mine?.lastNudgeAt = mine.lastNudgeAt
                    }
                }
                if erased {
                    $0.theirs = nil
                } else if let theirs {
                    $0.theirs = theirs
                }
                $0.isPaired = true
                $0.lastSyncedAt = Date()
            }
        }

        // An unlink can land mid-refresh (the status write above checks under the
        // lock); past this point nothing from the ex's zone may be filed either.
        guard await MainActor.run(body: { store.pairing != nil }) else { return .empty }

        // Status history rides the refresh, gated on the status *record* changing
        // (not a nudge-only delta); the log itself dedups by (fromMe, updatedAt).
        // A rename restamps the record without changing the status; the
        // sender writes no `StatusLog` for it, and neither does this side.
        if let theirs, theirStatus != nil, !erased,
           !(previousStatus.map { $0.emoji == theirs.emoji && $0.message == theirs.message
                                   && $0.isCelebration == theirs.isCelebration } ?? false) {
            StatusHistoryLog.shared.record(theirs, fromMe: false)
        }
        if let mine, myStatus != nil {
            // Own statuses set on this device are logged at set time; this
            // catches ones written by another device on the same account.
            StatusHistoryLog.shared.record(mine, fromMe: true)
        }
        // The durable log: one entry per `StatusLog` record. Same dedup key as
        // the two lines above, so a status and its log record collapse into one.
        StatusHistoryLog.shared.record(logEntries)

        // Bound to a `let` before crossing actors: capturing the mutable array is a data race.
        let arrived = moments.sorted { $0.sentAt < $1.sentAt }
        if arrived.isEmpty {
            if removedMoments {
                // A deletions-only delta still invalidates snapshot fields derived from
                // the index — otherwise the photo widget points at deleted files.
                await MainActor.run { store.refreshDerived() }
            } else {
                SharedStore.reloadWidgets()
            }
        } else {
            await MainActor.run { store.record(arrived) }
            await downloadRecentMedia(for: arrived, pairing: pairing, in: database)
        }

        // After the moments above are in the index — a receipt arriving in the
        // same delta (a full resync) must find the entries it refers to.
        if let theirReceipts {
            MomentIndex.shared.applyPartnerReceipts(Self.receiptMap(from: theirReceipts))
            let statusSeen = Self.statusSeen(from: theirReceipts)
            await MainActor.run {
                _ = store.mutate(reloadWidgets: false) { $0.myStatusSeenByPartner = statusSeen }
            }
        }

        let newFromPartner = arrived.filter { !$0.fromMe && !alreadyKnown.contains($0.id) }
        return RefreshResult(partnerStatus: partnerErased ? nil : (theirs ?? previousStatus),
                             newPartnerMoments: newFromPartner)
    }

    /// Only the newest few, so a first sync after reinstall doesn't pull down
    /// hundreds of photos and recordings at once. The rest arrive on demand.
    func downloadRecentMedia(for moments: [Moment],
                                     pairing: PairingInfo,
                                     in database: CKDatabase) async {
        let recent = moments.sorted { $0.sentAt > $1.sentAt }.prefix(10)
        for moment in recent where !MomentStore.shared.hasMedia(for: moment) {
            try? await downloadMedia(for: moment, pairing: pairing, in: database)
        }
        SharedStore.reloadWidgets()
    }
}
