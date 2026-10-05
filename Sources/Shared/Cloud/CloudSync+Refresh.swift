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
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            throw SyncError.notPaired
        }
        // `requirePairing`'s account check, alongside the fetch rather than before
        // it — a cold extension's lookup is a round trip of its own. Judged before
        // anything is applied, so nothing is filed under another account.
        async let sameAccount = isPairingAccount(pairing)
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
            guard await sameAccount else { throw SyncError.differentAccount }
            // The other side unlinked, or the zone is briefly gone mid-handshake.
            throw try await zoneGoneVerdict(pairing)
        }
        guard await sameAccount else { throw SyncError.differentAccount }
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
        let applied = await apply(changes, pairing: pairing, fullResync: previous == nil)
        var result = applied.result
        result.incomplete = changes.moreComing

        // A complete fetch of the whole zone is the one moment "not returned"
        // means "not on the server": own sends marked delivered that it didn't
        // return go back in the retry queue (`requeueMissingUploads`). Judged by
        // record name, so a copy this process couldn't decrypt still counts as
        // present. App only — an extension's batch is never the whole zone.
        // Not while a `FreshStart` record is unreadable: after a clear every own
        // moment is "missing", and the record saying so is what this pass couldn't read.
        let freshStartNames = [pairing.role.freshStartRecordName, pairing.role.other.freshStartRecordName]
        let freshStartHeld = result.unreadableRecordNames.contains(where: freshStartNames.contains)
        if previous == nil, !changes.moreComing, !Self.isAppExtension, !freshStartHeld {
            let delivered = Set(changes.records.compactMap {
                pairing.role.momentID(fromRecordName: $0.recordID.recordName)
            })
            // After a fresh start "not returned" is mostly "cleared": those stay
            // out of the queue, or a second device's old index re-sends them all.
            let clearedBefore = await MainActor.run { SharedStore.shared.snapshot.freshStart.clearedBefore }
            let requeued = MomentIndex.shared.requeueMissingUploads(
                delivered: delivered, hasMedia: MomentStore.shared.hasMedia, clearedBefore: clearedBefore)
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
        // One batch of a larger delta (an extension's) that read everything
        // still leaves the hold: the held records may be in the rest.
        var readable = true
        switch TokenAdvancePolicy.holdStep(unreadable: result.unreadableRecordNames, incomplete: changes.moreComing) {
        case .note(let names):
            readable = await MainActor.run { SharedStore.shared.noteUnreadableRecords(names) }
            if !readable {
                log.notice("\(names.count) records arrived unreadable; keeping the change token so they're fetched again.")
            }
        case .clear:
            await MainActor.run { SharedStore.shared.clearUnreadableHold() }
        case .keep:
            break
        }
        if let token = changes.token {
            let encoded = Self.encodeToken(token)
            let hadToken = previous != nil
            let readable = readable
            await MainActor.run {
                let store = SharedStore.shared
                let persists = TokenAdvancePolicy.persists(fetchedToken: true,
                                                           readable: readable,
                                                           samePairing: store.pairing?.sameZone(as: pairing) == true,
                                                           hadToken: hadToken,
                                                           tokenStillStored: store.changeToken(for: tokenKey) != nil)
                guard persists else {
                    if readable { log.notice("Not advancing the change token: the pairing or the stored token changed during apply.") }
                    return
                }
                store.setChangeToken(encoded, for: tokenKey)
            }
        }

        // Media last, after the token: the records are filed, so a kill here
        // loses nothing, and the notification service's banner no longer waits
        // behind a backlog of full-size photos. The app's full downloads run on
        // their own, so announcing and the recovery pass don't wait on them.
        if Self.prefetchProcess == .app {
            let arrived = applied.arrived
            let fullResync = previous == nil && !changes.moreComing
            Task {
                await self.prefetchMedia(for: arrived, pairing: pairing)
                if fullResync { await self.prefetchMissingThumbnails(pairing: pairing) }
            }
        } else {
            await prefetchMedia(for: applied.arrived, pairing: pairing)
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
        /// The zone's own failure. It can arrive only here, with the operation
        /// "succeeding" — an empty delta that looked complete.
        var zoneError: Error?
    }

    /// Every field a refresh reads; assets stay out (see `fetchZoneChanges`).
    /// `IngestTests` checks every non-asset `Field` is here: one missing reads nil.
    static let changeFetchKeys: [String] = [
        Field.emoji, Field.message, Field.displayName, Field.updatedAt,
        Field.isCelebration,
        Field.count,
        Field.momentID, Field.kind, Field.caption, Field.senderName, Field.sentAt,
        Field.duration, Field.waveform,
        Field.seenMap, Field.statusSeenAt, Field.statusSeenFor,
        Field.startsAt, Field.timeZone,
        Field.requestedAt,
        Field.stage, Field.epoch, Field.clearedBefore,
    ]

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
            desiredKeys: Self.changeFetchKeys
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
            switch result {
            case .success(let value):
                changes.token = value.serverChangeToken
                changes.moreComing = value.moreComing
            case .failure(let error):
                changes.zoneError = error
            }
        }

        // Without the cancellation handler the operation runs to completion regardless,
        // stalling the widget's getTimeline for the full network duration.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        if let zoneError = changes.zoneError {
                            continuation.resume(throwing: zoneError)
                        } else {
                            continuation.resume(returning: changes)
                        }
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// Files a batch of changed records into local state. The decisions are
    /// `ParsedDelta`'s (pure, tested); this performs its writes, in this order.
    /// `arrived` is every new moment, own and partner's, for `prefetchMedia`.
    func apply(_ changes: ZoneChanges,
               pairing: PairingInfo,
               fullResync: Bool = false) async -> (result: RefreshResult, arrived: [Moment]) {
        let (hidden, freshStart, announcedFloor) = await MainActor.run {
            let snapshot = SharedStore.shared.snapshot
            return (SharedStore.shared.hiddenMomentIDs, snapshot.freshStart, snapshot.lastAnnouncedMomentSentAt)
        }
        let names = myRecordNames(pairing)
        var metadata = RecordMetadata.server
        metadata.isForeign = { Self.isForeign($0, names: names) }
        let parsed = ParsedDelta.parse(records: changes.records,
                                       deletedIDs: changes.deletedIDs,
                                       mineRole: pairing.role,
                                       hidden: hidden,
                                       freshStart: freshStart,
                                       metadata: metadata)
        if !parsed.unreadable.isEmpty {
            log.notice("\(parsed.unreadable.count) records in this delta had unreadable encrypted fields.")
        }
        if parsed.beforeEpoch > 0 {
            log.notice("\(parsed.beforeEpoch) records from before the fresh start were left unfiled.")
        }
        if parsed.foreignFreshStart {
            log.error("Our FreshStart record was written by another account; ignored.")
        }

        // Captured before the deletions and the insert below, so "new" can mean
        // "not already stored".
        let held = MomentIndex.shared.load()
        let alreadyKnown = Set(held.map(\.id))
        let oldestRetained = held.count >= AppConfig.momentHistoryLimit
            ? held[AppConfig.momentHistoryLimit - 1].sentAt : nil

        for id in parsed.removedMomentIDs {
            MomentIndex.shared.remove(id: id)
            MomentStore.shared.delete(id: id)
        }
        // The cloud cap pruning the oldest entries, mirrored locally.
        StatusHistoryLog.shared.remove(fromMe: true, at: parsed.removedMyLogs)
        StatusHistoryLog.shared.remove(fromMe: false, at: parsed.removedTheirLogs)

        let store = SharedStore.shared
        let (previousTheirs, previousMine, minePublished) = await MainActor.run {
            (store.snapshot.theirs, store.snapshot.mine, store.snapshot.myStatusPublished)
        }
        let outcome = parsed.outcome(mineRole: pairing.role,
                                     previousMine: previousMine,
                                     previousTheirs: previousTheirs,
                                     minePublished: minePublished,
                                     alreadyKnown: alreadyKnown,
                                     hidden: hidden,
                                     oldestRetained: oldestRetained,
                                     fullResync: fullResync,
                                     announcedFloor: announcedFloor)
        // Bound to `let`s before crossing actors.
        let fold = outcome.fold
        let complete = !changes.moreComing

        await MainActor.run {
            _ = store.mutate(reloadWidgets: false) {
                // Checked *inside* the locked mutate, by zone identity: an unlink
                // — or an unlink and a new pairing — can land mid-refresh, and
                // writing this delta would file the ex's records onto the wrong snapshot.
                guard store.pairing?.sameZone(as: pairing) == true else { return }
                fold.fold(into: &$0)
                $0.isPaired = true
                // Only a complete fetch counts as synced: the widget skips its own
                // fetch after a recent sync, and one batch of a large delta isn't one.
                if complete { $0.lastSyncedAt = Date() }
            }
        }

        // An unlink can land mid-refresh (the status write above checks under the
        // lock); past this point nothing from the ex's zone may be filed either.
        guard await MainActor.run(body: { store.pairing?.sameZone(as: pairing) == true }) else { return (.empty, []) }

        if let theirs = outcome.partnerStatusToLog { StatusHistoryLog.shared.record(theirs, fromMe: false) }
        if let mine = outcome.myStatusToLog { StatusHistoryLog.shared.record(mine, fromMe: true) }
        // The durable log: one entry per `StatusLog` record, same dedup key as the
        // two lines above, so a status and its log record collapse into one.
        // Re-judged inside each store's lock against the epoch as it is then.
        let created = Self.serverCreationTimes(changes.records, mineRole: pairing.role)
        StatusHistoryLog.shared.record(parsed.logEntries) {
            let epoch = SharedStore.shared.snapshot.freshStart.clearedBefore
            let isCleared = FreshStartPolicy.clearedFilter(createdAt: created.logs, epoch: epoch)
            return { isCleared(FreshStartPolicy.LogKey(fromMe: $0.fromMe, at: $0.at)) }
        }

        let arrived = outcome.arrived
        if arrived.isEmpty {
            if !parsed.removedMomentIDs.isEmpty {
                // A deletions-only delta still invalidates snapshot fields derived from
                // the index — otherwise the photo widget points at deleted files.
                await MainActor.run { _ = store.refreshDerived() }
            } else {
                SharedStore.reloadWidgets()
            }
        } else {
            await MainActor.run {
                store.record(arrived) {
                    let epoch = SharedStore.shared.snapshot.freshStart.clearedBefore
                    let isCleared = FreshStartPolicy.clearedFilter(createdAt: created.moments, epoch: epoch)
                    return { isCleared($0.id) }
                }
            }
        }

        // After the moments above are in the index — a receipt arriving in the
        // same delta (a full resync) must find the entries it refers to.
        if let receipts = parsed.theirReceipts {
            MomentIndex.shared.applyPartnerReceipts(Self.receiptMap(from: receipts))
        }
        return (outcome.result, arrived)
    }

    /// Each moment's and status log's server creation time, for the fresh
    /// start's under-lock filter.
    static func serverCreationTimes(_ records: [CKRecord],
                                    mineRole: PairRole) -> (moments: [String: Date], logs: [FreshStartPolicy.LogKey: Date]) {
        var moments: [String: Date] = [:]
        var logs: [FreshStartPolicy.LogKey: Date] = [:]
        for record in records {
            guard let created = record.creationDate ?? record.modificationDate else { continue }
            let name = record.recordID.recordName
            for side in [mineRole, mineRole.other] {
                if let id = side.momentID(fromRecordName: name) { moments[id] = created }
                if let date = side.statusLogDate(fromRecordName: name) {
                    logs[FreshStartPolicy.LogKey(fromMe: side == mineRole, at: date)] = created
                }
            }
        }
        return (moments, logs)
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
        case RecordType.freshStart:
            return record.encryptedValues[Field.stage] != nil
        default:
            return true
        }
    }

    static var prefetchProcess: MediaPrefetchPlan.Process {
        if SharedStore.isRunningInWidgetExtension { return .widget }
        return isAppExtension ? .notificationService : .app
    }

    /// Runs this process's `MediaPrefetchPlan` after a refresh (the app's also
    /// covers the index's newest). Stops at a cancellation, or when the pairing
    /// changed underneath (the ex's photos must not land in the new pairing's
    /// store) — the records are already applied and the token saved, so nothing is lost.
    func prefetchMedia(for arrived: [Moment], pairing: PairingInfo) async {
        let database = self.database(for: pairing)
        let store = MomentStore.shared
        let process = Self.prefetchProcess
        let recent = process == .app ? Array(MomentIndex.shared.load().prefix(MediaPrefetchPlan.appLimit)) : []
        // A kind from a newer build has no media this build knows to fetch.
        let items = MediaPrefetchPlan.items(for: arrived.filter(\.kind.isSupported),
                                            recent: recent.filter(\.kind.isSupported), in: process,
                                            hasMedia: store.hasMedia,
                                            hasThumbnail: { store.hasThumbnail(for: $0.id) })
        guard !items.isEmpty else { return }
        let samePairing = { await MainActor.run { SharedStore.shared.pairing?.sameZone(as: pairing) == true } }
        for item in items {
            // Per item: ten photos can outlast an unlink.
            guard !Task.isCancelled, await samePairing() else { break }
            if process == .app {
                try? await download(item.fetch, for: item.moment, pairing: pairing, in: database)
            } else {
                // Extensions are inside a budget (the banner's, the timeline's):
                // a stalled thumbnail gives up rather than eat it.
                let fetch = item.fetch, moment = item.moment
                try? await withDeadline(AppConfig.widgetDeadline) {
                    try await self.download(fetch, for: moment, pairing: pairing, in: self.database(for: pairing))
                }
            }
            // Landed after an unlink's wipe: not this pairing's any more.
            if await !samePairing() {
                store.delete(id: item.moment.id)
                break
            }
        }
        SharedStore.reloadWidgets()
    }
}
