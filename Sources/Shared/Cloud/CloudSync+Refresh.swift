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

        // Extensions live under a 24–30 MB ceiling: they take one batch of a
        // large delta and leave the rest to the app, which finishes the resync.
        let oneBatch = Self.isAppExtension
        let changes: ZoneChanges
        do {
            changes = try await fetchZoneChanges(zone: zone, in: database, since: previous, oneBatch: oneBatch)
        } catch let error as CKError where Self.isTokenExpired(error) {
            // Token expiry is zone-scoped, so it arrives wrapped in .partialFailure —
            // matching only the bare code left every refresh failing forever.
            log.notice("Change token expired, resyncing the whole zone.")
            previous = nil
            await MainActor.run { SharedStore.shared.setChangeToken(nil, for: tokenKey) }
            changes = try await fetchZoneChanges(zone: zone, in: database, since: nil, oneBatch: oneBatch)
        } catch let error as CKError where Self.isAlreadyGone(error) {
            // The other side unlinked, or the zone is briefly gone mid-handshake.
            throw try await zoneGoneVerdict(pairing)
        }
        // A deadline landing here (the widget's) must stop before anything is
        // applied: a half-applied delta must not be followed by its token.
        try Task.checkCancellation()
        // The zone answered: any earlier "gone" sighting was transient.
        await MainActor.run { SharedStore.shared.zoneGoneSeenAt = nil }
        if changes.moreComing {
            log.notice("Took one batch of \(changes.records.count) records; the app will fetch the rest.")
        }

        // Apply first, then advance the token: the other order can persist the token
        // without the records (the extension gets killed on a deadline), losing them
        // forever. Re-applying the same delta twice is tolerated everywhere here.
        var result = await apply(changes, pairing: pairing, database: database)
        result.incomplete = changes.moreComing

        // A complete fetch of the whole zone is the one moment "not returned"
        // means "not on the server": own sends marked delivered that it didn't
        // return go back in the retry queue (`requeueMissingUploads`). Judged by
        // record name, so a copy this process couldn't decrypt still counts as
        // present. App only — an extension's batch is never the whole zone.
        if previous == nil, !changes.moreComing, !Self.isAppExtension {
            let delivered = Set(changes.records.compactMap {
                pairing.role.momentID(fromRecordName: $0.recordID.recordName)
            })
            let requeued = MomentIndex.shared.requeueMissingUploads(
                delivered: delivered, hasMedia: MomentStore.shared.hasMedia)
            if !requeued.isEmpty {
                log.error("\(requeued.count) own moment(s) marked sent were missing from the zone; re-queued for upload.")
                result.requeuedUploads = requeued.count
            }
        }

        // Readable before token: a record whose encrypted fields came back empty
        // (a background process without the share's keys) carried nothing into
        // local state, and advancing past it would lose its words for good. The
        // one exception is the app giving up on records it has failed to read on
        // several separate looks — otherwise a single unreadable record pins the
        // token, and the whole delta behind it, forever (`noteUnreadableRecords`).
        var advanceToken = true
        if !result.unreadableRecordNames.isEmpty {
            let names = result.unreadableRecordNames
            advanceToken = await MainActor.run { SharedStore.shared.noteUnreadableRecords(names) }
            if !advanceToken {
                log.notice("\(names.count) records arrived unreadable; keeping the change token so they're fetched again.")
            }
        } else {
            await MainActor.run { SharedStore.shared.clearUnreadableHold() }
        }
        if advanceToken, let token = changes.token {
            let encoded = Self.encodeToken(token)
            let hadToken = previous != nil
            await MainActor.run {
                let store = SharedStore.shared
                // An unlink (or unlink + re-pair) mid-refresh: writing this token
                // would hand the next pairing a cursor into a zone that's gone.
                guard store.pairing?.sameZone(as: pairing) == true else { return }
                // A corrupt moment index found during `apply` cleared the tokens
                // so the next refresh rebuilds the history from the whole zone;
                // writing this one back would leave the index truncated for good.
                if hadToken, store.changeToken(for: tokenKey) == nil {
                    log.notice("Change token was cleared during apply (index rebuild); not advancing it.")
                    return
                }
                store.setChangeToken(encoded, for: tokenKey)
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
        /// `oneBatch` stopped short; `token` continues from where it stopped.
        var moreComing = false
    }

    /// Records an extension takes per refresh before handing over to the app.
    static let extensionBatchLimit = 150

    /// Whether this process is the widget or the notification service.
    static var isAppExtension: Bool { SharedStore.processLabel != "app" }

    /// Assets are excluded via `desiredKeys` — a first sync would otherwise pull
    /// every photo and recording ever sent. Media is fetched separately, on demand.
    /// `oneBatch` returns after the first page with `moreComing` set; the page's
    /// token is a valid cursor, so applying it before persisting stays safe.
    func fetchZoneChanges(zone: CKRecordZone.ID,
                                  in database: CKDatabase,
                                  since previous: CKServerChangeToken?,
                                  oneBatch: Bool = false) async throws -> ZoneChanges {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: previous,
            resultsLimit: oneBatch ? Self.extensionBatchLimit : nil,
            desiredKeys: [
                Field.emoji, Field.message, Field.displayName, Field.updatedAt,
                Field.isCelebration,
                Field.count,
                Field.momentID, Field.kind, Field.caption, Field.senderName, Field.sentAt,
                Field.duration, Field.waveform,
                Field.seenMap, Field.statusSeenAt, Field.statusSeenFor,
                Field.startsAt, Field.timeZone,
                Field.requestedAt,
            ]
        )

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: configuration]
        )
        operation.fetchAllChanges = !oneBatch

        let changes = ZoneChanges()
        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result { changes.records.append(record) }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            changes.deletedIDs.append(recordID)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            if case .success(let value) = result {
                changes.token = value.serverChangeToken
                changes.moreComing = value.moreComing
            }
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
        var anniversaryRecord: CKRecord?
        var requestRecord: CKRecord?
        var moments: [Moment] = []
        var logEntries: [StatusHistoryEntry] = []
        var unreadable: [String] = []
        // Parsed from plaintext fields only (captions come back empty), for the
        // banner's wording — never filed into the index.
        var heldMoments: [Moment] = []

        for record in changes.records {
            let name = record.recordID.recordName
            // Every type below always carries its probe field; an empty one means
            // the process couldn't decrypt, and the record is left for a later fetch.
            guard Self.isReadable(record) else {
                unreadable.append(name)
                if record.recordType == RecordType.moment,
                   let moment = Self.moment(from: record, mineRole: mineRole, theirsRole: theirsRole),
                   !moment.fromMe {
                    heldMoments.append(moment)
                }
                continue
            }
            switch record.recordType {
            case RecordType.status:
                if name == mineRole.statusRecordName { myStatus = record }
                if name == theirsRole.statusRecordName { theirStatus = record }
            case RecordType.nudge:
                if name == mineRole.nudgeRecordName { myNudge = record }
                if name == theirsRole.nudgeRecordName { theirNudge = record }
            case RecordType.receipt:
                if name == theirsRole.receiptRecordName { theirReceipts = record }
            case RecordType.anniversary:
                if name == Self.anniversaryRecordName { anniversaryRecord = record }
            case RecordType.anniversaryRequest:
                if name == Self.anniversaryRequestRecordName { requestRecord = record }
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
        if !unreadable.isEmpty {
            log.notice("\(unreadable.count) records in this delta had unreadable encrypted fields.")
        }

        // Reported moments stay reported: the record lives on in the sender's
        // iCloud and every full resync re-delivers it.
        let hidden = await MainActor.run { SharedStore.shared.hiddenMomentIDs }
        moments.removeAll { hidden.contains($0.id) }

        // Captured before the insert below, so "new" can mean "not already
        // stored" — a full resync re-delivers the entire history, and reporting
        // it all as new re-announced already-seen moments.
        let alreadyKnown = MomentIndex.shared.knownIDs()

        // The partner deleting their own status record is how a participant
        // unlinks (they can't delete the owner's zone). Must not be ignored.
        var partnerErased = false
        var anniversaryErased = false
        var requestErased = false
        var removedMoments = false
        var removedMyLogs: [Date] = []
        var removedTheirLogs: [Date] = []
        for recordID in changes.deletedIDs {
            let name = recordID.recordName
            if name == theirsRole.statusRecordName { partnerErased = true }
            if name == Self.anniversaryRecordName { anniversaryErased = true }
            if name == Self.anniversaryRequestRecordName { requestErased = true }
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
        if anniversaryRecord != nil { anniversaryErased = false }
        if requestRecord != nil { requestErased = false }

        let store = SharedStore.shared
        let (previousStatus, previousMine, minePublished) = await MainActor.run {
            (store.snapshot.theirs, store.snapshot.mine, store.snapshot.myStatusPublished)
        }

        // A status record and its nudge counter arrive independently; fold
        // each into what was already known.
        let mine = Self.payload(from: myStatus, nudge: myNudge, existing: previousMine, fromPartner: false)
        // Our own records moved on the server — another device on this iCloud
        // account did it. Judged against what was held, not "arrived": a full
        // resync re-delivers everything and changes nothing. An unpublished
        // local edit legitimately differs from the server copy, so it doesn't count.
        let ownRecordsChanged = (myStatus != nil && minePublished && mine?.updatedAt != previousMine?.updatedAt)
            || (myNudge != nil && mine?.nudgeCount != previousMine?.nudgeCount)
            || moments.contains { $0.fromMe && !alreadyKnown.contains($0.id) }
        let theirs = partnerErased ? nil : Self.payload(from: theirStatus, nudge: theirNudge,
                                                        existing: previousStatus)
        // Bound to a `let` before crossing actors: capturing the mutable locals
        // is a data race under strict concurrency.
        let delta = RefreshDelta(
            mine: mine,
            theirs: theirs,
            partnerErased: partnerErased,
            anniversary: anniversaryRecord.flatMap(Self.anniversary(from:)),
            anniversaryErased: anniversaryErased,
            receiptReadable: theirReceipts != nil,
            statusSeen: theirReceipts.flatMap(Self.statusSeen(from:)),
            anniversaryRequestedAt: requestRecord.flatMap(Self.anniversaryRequestDate(from:)),
            anniversaryRequestErased: requestErased,
            unreadableRecords: unreadable.count
        )
        let erased = partnerErased
        let complete = !changes.moreComing

        await MainActor.run {
            _ = store.mutate(reloadWidgets: false) {
                // Checked *inside* the locked mutate, by zone identity: an unlink
                // — or an unlink and a new pairing — can land mid-refresh, and
                // writing this delta would file the ex's records onto the wrong snapshot.
                guard store.pairing?.sameZone(as: pairing) == true else { return }
                delta.fold(into: &$0)
                $0.isPaired = true
                // Only a complete fetch counts as synced: the widget skips its own
                // fetch after a recent sync, and one batch of a large delta isn't one.
                if complete { $0.lastSyncedAt = Date() }
            }
        }

        // An unlink can land mid-refresh (the status write above checks under the
        // lock); past this point nothing from the ex's zone may be filed either.
        guard await MainActor.run(body: { store.pairing?.sameZone(as: pairing) == true }) else { return .empty }

        // Status history rides the refresh, gated on the status *record* changing
        // (not a nudge-only delta); the log itself dedups by (fromMe, updatedAt).
        // A rename restamps the record without changing the status; the
        // sender writes no `StatusLog` for it, and neither does this side.
        if let theirs, theirStatus != nil, !erased,
           !(previousStatus.map { $0.emoji == theirs.emoji && $0.message == theirs.message
                                   && $0.isCelebration == theirs.isCelebration } ?? false) {
            StatusHistoryLog.shared.record(theirs, fromMe: false)
        }
        if let mine, myStatus != nil, !(previousMine.map { $0.sameWords(as: mine) } ?? false) {
            // Own statuses set on this device are logged at set time; this
            // catches ones written by another device on the same account. Not
            // the echo of a rename: same words, new stamp, would log twice.
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
        }

        let newFromPartner = arrived.filter { !$0.fromMe && !alreadyKnown.contains($0.id) }
        // Same "new" test as above: a resync re-delivering history unreadable is not news.
        let heldKinds = heldMoments
            .filter { !alreadyKnown.contains($0.id) && !hidden.contains($0.id) }
            .sorted { $0.sentAt < $1.sentAt }
            .map(\.kind)
        return RefreshResult(partnerStatus: erased ? nil : (theirs ?? previousStatus),
                             newPartnerMoments: newFromPartner,
                             unreadableRecordNames: unreadable,
                             ownRecordsChanged: ownRecordsChanged,
                             heldPartnerMomentKinds: heldKinds,
                             heldPartnerStatus: unreadable.contains(theirsRole.statusRecordName))
    }

    /// Whether the process could decrypt this record. Each type is probed on a
    /// field every version of the app has always written; `Nudge` has none.
    static func isReadable(_ record: CKRecord) -> Bool {
        switch record.recordType {
        case RecordType.status, RecordType.statusLog:
            return record.encryptedValues[Field.emoji] != nil
        case RecordType.moment:
            return record.encryptedValues[Field.senderName] != nil
                || record.encryptedValues[Field.caption] != nil
        case RecordType.receipt:
            return record.encryptedValues[Field.seenMap] != nil
        case RecordType.anniversary:
            return record.encryptedValues[Field.startsAt] != nil
        case RecordType.anniversaryRequest:
            return record.encryptedValues[Field.requestedAt] != nil
        default:
            return true
        }
    }

    /// Only the newest few, so a first sync after reinstall doesn't pull down
    /// hundreds of photos and recordings at once. The rest arrive on demand.
    /// The widget takes only the thumbnails it draws, and every process stops
    /// at a cancellation — the records are already applied, so nothing is lost.
    func downloadRecentMedia(for moments: [Moment],
                                     pairing: PairingInfo,
                                     in database: CKDatabase) async {
        let thumbnailsOnly = SharedStore.isRunningInWidgetExtension
        let recent = moments.sorted { $0.sentAt > $1.sentAt }.prefix(thumbnailsOnly ? 3 : 10)
        for moment in recent where !Task.isCancelled {
            if thumbnailsOnly {
                guard !moment.isVoice, !MomentStore.shared.hasThumbnail(for: moment.id) else { continue }
                try? await fetchThumbnail(for: moment)
            } else if !MomentStore.shared.hasMedia(for: moment) {
                try? await downloadMedia(for: moment, pairing: pairing, in: database)
            }
        }
        SharedStore.reloadWidgets()
    }
}
