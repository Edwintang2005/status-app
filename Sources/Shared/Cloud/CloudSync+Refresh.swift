import CloudKit
import Foundation
import os

// The change fetch and how a delta folds into local state. Records are applied
// before the token is persisted (CLAUDE.md invariant 2).
extension CloudSync {
    /// Pulls everything changed in the shared zone since last time. A change fetch,
    /// not queries: moments have UUID names, and a device with no stored token gets
    /// the entire zone back — which is how a reinstall recovers the full history.
    /// The app takes it in batches of `appBatchLimit`, each filed and its token kept
    /// before the next, so a slow link's resync of a long history gains ground on
    /// every pass rather than losing it all at `refreshDeadline`. Extensions live
    /// under a 24–30 MB ceiling: they take one batch and leave the rest to the app.
    @discardableResult
    func refresh() async throws -> RefreshResult {
        let started = Date()
        let pairing: PairingInfo
        switch await MainActor.run(body: { self.stores.shared.pairingState }) {
        case .paired(let info): pairing = info
        case .unpaired: throw SyncError.notPaired
        case .unreadable: throw SyncError.storeUnreadable
        }
        // `requirePairing`'s account check, alongside the fetch rather than before
        // it — a cold extension's lookup is a round trip of its own. Judged before
        // anything is applied, so nothing is filed under another account.
        async let sameAccount = isPairingAccount(pairing)
        let database = cloudDatabase(for: pairing)
        let zone = zoneID(for: pairing)
        let tokenKey = SharedStore.changeTokenKey(for: pairing.role)
        let batchLimit = isExtension ? Self.extensionBatchLimit : Self.appBatchLimit

        var sweep = Sweep()
        while true {
            // Past the deadline no further batch starts; the ones filed keep their tokens.
            if sweep.batches > 0 { try Task.checkCancellation() }
            // `startedFrom` is the stored bytes this batch continues: only a fetch that
            // still continues them when it lands may finish a sweep (`HistoryCoverage`).
            let start = await MainActor.run {
                let stored = self.stores.shared.changeToken(for: tokenKey)
                return (stored: stored, sweeping: self.stores.shared.historyCoverage == HistoryCoverage.owed)
            }
            // Bytes that can't resume a fetch are no token: it starts over, as a resync.
            var previous = start.stored.flatMap { database.canResume(from: $0) ? $0 : nil }
            var startedFrom = start.stored
            // Another process's batch landed between ours: what it read isn't in `delivered`.
            if sweep.batches > 0, start.stored != sweep.lastKept { sweep.unbroken = false }

            let changes: ZoneChanges
            do {
                changes = try await fetchZoneChanges(zone: zone, in: database, since: previous, batchLimit: batchLimit)
            } catch let error as CKError where Self.isTokenExpired(error) {
                log.notice("Change token expired, resyncing the whole zone.")
                previous = nil
                startedFrom = nil
                if sweep.batches > 0 { sweep.unbroken = false }
                await MainActor.run { self.stores.shared.setChangeToken(nil, for: tokenKey) }
                changes = try await fetchZoneChanges(zone: zone, in: database, since: nil, batchLimit: batchLimit)
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
            await MainActor.run { self.stores.shared.zoneGoneSeenAt = nil }
            if changes.moreComing, isExtension {
                log.notice("Took one batch of \(changes.records.count) records; the app will fetch the rest.")
            }

            if sweep.batches == 0 { sweep.fromNothing = previous == nil }
            // A sweep another process began (its first batch kept a token) is still a
            // resync to the batches that finish it: old history isn't news.
            sweep.resync = sweep.resync || previous == nil || start.sweeping
            let batch = await file(changes, pairing: pairing, tokenKey: tokenKey, hadToken: previous != nil,
                                   startedFrom: startedFrom, resync: sweep.resync,
                                   missedEarlier: !sweep.result.unreadableRecordNames.isEmpty,
                                   readEarlier: sweep.newestRead)
            sweep.batches += 1
            sweep.result.append(batch.result)
            sweep.arrived += batch.arrived
            sweep.newestRead = [sweep.newestRead, batch.newestRead].compactMap { $0 }.max()
            sweep.delivered += changes.records.map(\.recordID) + changes.failedIDs
            sweep.finished = !changes.moreComing
            sweep.lastKept = batch.kept
            // Held or refused, the token stayed: the next batch would be this one again.
            guard !isExtension, changes.moreComing, batch.kept != nil else { break }
        }
        if sweep.batches > 1 { log.notice("Fetched the zone in \(sweep.batches) batches.") }
        var result = sweep.result

        // A complete fetch of the whole zone is the one moment "not returned"
        // means "not on the server": own sends marked delivered that it didn't
        // return go back in the retry queue (`requeueMissingUploads`). Judged by
        // record name, so a copy this process couldn't decrypt still counts as
        // present. App only — an extension's batch is never the whole zone.
        // Not while a `FreshStart` record is unreadable: after a clear every own
        // moment is "missing", and the record saying so is what this pass couldn't read.
        let freshStartNames = [pairing.role.freshStartRecordName, pairing.role.other.freshStartRecordName]
        let stillOwed = await MainActor.run { self.stores.shared.unreadableTally.heldNames }
        let freshStartHeld = (result.unreadableRecordNames + stillOwed).contains(where: freshStartNames.contains)
        if sweep.isWholeZone, !isExtension, !freshStartHeld {
            // A record that failed to arrive is still on the server.
            let delivered = Set(sweep.delivered.compactMap { pairing.role.momentID(fromRecordName: $0.recordName) })
            // After a fresh start "not returned" is mostly "cleared": those stay
            // out of the queue, or a second device's old index re-sends them all.
            let clearedBefore = await MainActor.run { self.stores.shared.snapshot.freshStart.clearedBefore }
            let requeued = self.stores.index.requeueMissingUploads(
                delivered: delivered, hasMedia: self.stores.media.hasMedia, clearedBefore: clearedBefore)
            if !requeued.isEmpty {
                log.error("\(requeued.count) own moment(s) marked sent were missing from the zone; re-queued for upload.")
            }
        }

        // Owed from earlier passes, fetched by ID — by a pass that missed nothing
        // itself: the app only with the phone unlocked; the widget and expanded
        // banner on any pass with budget left (they're what catch up after an
        // unlock; a blind miss backs them off, `claimOwedRetry`); never the
        // notification service, whose time is the banner's.
        var arrived = sweep.arrived
        let processLabel = processLabel
        if result.unreadableRecordNames.isEmpty, isExtension || SharedStore.protectedDataAvailable,
           processLabel != "notification service",
           !isExtension || Date().timeIntervalSince(started) < AppConfig.owedRetryExtensionBudget,
           let retried = await retryOwedRecords(pairing: pairing, database: database) {
            result.absorb(retried.result)
            arrived += retried.arrived
        }

        // Media last, after the token: the records are filed, so a kill here
        // loses nothing, and the notification service's banner no longer waits
        // behind a backlog of full-size photos. The app's full downloads run on
        // their own, so announcing and the recovery pass don't wait on them.
        // A test's fake database has nothing to download.
        guard prefetchesMedia else { return result }
        if Self.prefetchProcess == .app {
            let arrived = arrived
            let fullResync = sweep.fromNothing && sweep.finished
            Task {
                await self.prefetchMedia(for: arrived, pairing: pairing)
                if fullResync { await self.prefetchMissingThumbnails(pairing: pairing) }
            }
        } else {
            await prefetchMedia(for: arrived, pairing: pairing)
        }
        return result
    }

    /// One refresh's batches, added up.
    struct Sweep {
        var batches = 0
        var result = RefreshResult.empty
        var arrived: [Moment] = []
        /// Every record name the batches returned, unreadable ones included.
        var delivered: [CKRecord.ID] = []
        /// The first batch had no token to continue: the whole zone, if it finishes.
        var fromNothing = false
        var resync = false
        /// Each batch continued the token the one before kept.
        var unbroken = true
        var finished = false
        var lastKept: Data?
        /// The newest server save any batch read, for `newsAfter` once the sweep completes.
        var newestRead: Date?

        var isWholeZone: Bool { fromNothing && unbroken && finished }
    }

    /// One batch filed (invariant 2): applied, what it missed owed — or, a resync
    /// that can't owe it, held — and only then its token kept.
    /// - Returns: also the token kept, `nil` when it wasn't.
    private func file(_ changes: ZoneChanges, pairing: PairingInfo, tokenKey: String, hadToken: Bool,
                      startedFrom: Data?, resync: Bool,
                      missedEarlier: Bool,
                      readEarlier: Date?) async -> (result: RefreshResult, arrived: [Moment], kept: Data?, newestRead: Date?) {
        let keysAvailable = !isExtension && SharedStore.protectedDataAvailable
        let tally = await MainActor.run { self.stores.shared.unreadableTally }
        let hold = ResyncHold(keysAvailable: keysAvailable,
                              room: AppConfig.owedRecordLimit - tally.owed.count,
                              heldPasses: tally.heldPasses)
        // Apply before the token (invariant 2); re-applying a delta is harmless.
        let applied = await apply(changes, pairing: pairing, fullResync: resync, hold: hold,
                                  missedEarlier: missedEarlier, readEarlier: readEarlier)
        var result = applied.result
        result.incomplete = changes.moreComing
        if !changes.failedIDs.isEmpty {
            log.notice("\(changes.failedIDs.count) changed records failed to arrive; owed, to fetch again by ID.")
            result.unreadableRecordNames += changes.failedIDs.map(\.recordName)
        }

        // What this batch missed is owed and fetched again by ID; what it read or
        // saw deleted is settled; the token moves on (invariant 2). Except a resync
        // a process without the keys couldn't read (a locked phone's, an
        // extension's): owing a whole zone's history would overflow the list and
        // lose it, so the token stays for a process that can read it.
        let missed = result.unreadableRecordNames
        let read = Set(changes.records.map(\.recordID.recordName)).subtracting(missed)
            .union(changes.deletedIDs.map(\.recordName))
        let holdsResync = hold.holds(fullResync: resync, missed: missed.count)
        // Held, only what the banners and the clear read: the partner's moments and
        // status, the fresh-start records — not a whole zone's names.
        let theirs = pairing.role.other
        let worthHolding = missed.filter {
            theirs.momentID(fromRecordName: $0) != nil || $0 == theirs.statusRecordName
                || $0 == theirs.freshStartRecordName || $0 == pairing.role.freshStartRecordName
        }
        let processLabel = processLabel
        if !missed.isEmpty {
            log.notice("\(missed.count) records arrived unreadable; \(holdsResync ? "keeping the token for this resync batch" : "owed, to fetch again by ID").")
        }
        await MainActor.run {
            // The ex's names never land on a new pairing's list.
            let store = self.stores.shared
            guard store.pairing?.sameZone(as: pairing) == true else { return }
            // A resync miss keeps the mark this pass judged against.
            store.noteFetched(missed: holdsResync ? [] : missed, resync: resync, newsAfter: applied.judgedNewsAfter,
                              settled: read,
                              holding: holdsResync ? (worthHolding, missed.count, keysAvailable) : nil,
                              process: processLabel)
        }
        guard let encoded = changes.token, !holdsResync else { return (result, applied.arrived, nil, applied.newestRead) }
        let finished = !changes.moreComing
        let kept = await MainActor.run { () -> Bool in
            let store = self.stores.shared
            let persists = TokenAdvancePolicy.persists(samePairing: store.pairing?.sameZone(as: pairing) == true,
                                                       hadToken: hadToken,
                                                       tokenStillStored: store.changeToken(for: tokenKey) != nil)
            guard persists else {
                log.notice("Not advancing the change token: the pairing or the stored token changed during apply.")
                return false
            }
            // Batches taken since the tokens were cleared add up to the whole zone,
            // as long as this one continued the stored lineage, not an older one.
            let sameLineage = store.changeToken(for: tokenKey) == startedFrom
            store.setChangeToken(encoded, for: tokenKey)
            store.noteFetched(missed: [], settled: [], tokenKept: true)
            // A sweep from no token is owed until a batch ends it, whichever process that is.
            let coverage = hadToken ? store.historyCoverage : HistoryCoverage.owed
            store.historyCoverage = HistoryCoverage.after(coverage, finished: finished && sameLineage)
            return true
        }
        return (result, applied.arrived, kept ? encoded : nil, applied.newestRead)
    }

    /// Owed records (`SharedStore.UnreadableTally`), fetched again by ID — claimed
    /// across processes once per `owedRetrySpacing` (longer for an extension after a
    /// blind miss), an extension only the newest `owedRetryExtensionLimit`, under its
    /// own `owedRetryDeadline` so a stall can't fail the fetch it follows — and filed
    /// like a delta: as one batch of many (not a complete sync); a resync's misses
    /// first and as a resync, judged against the mark each kept (re-fetched history
    /// isn't news, a new moment is); the rest incrementally (a moment that waited is
    /// news). Gone ones settle. A claim that fetched nothing is given back.
    func retryOwedRecords(pairing: PairingInfo, database: any CloudDatabase,
                          now: Date = Date()) async -> (result: RefreshResult, arrived: [Moment])? {
        guard !Task.isCancelled else { return nil }
        let isExtension = isExtension
        let limit = isExtension ? AppConfig.owedRetryExtensionLimit : AppConfig.owedRecordLimit
        guard let owed = await MainActor.run(body: {
            self.stores.shared.claimOwedRetry(now: now, limit: limit, isExtension: isExtension)
        }) else { return nil }
        let zone = zoneID(for: pairing)
        let ids = owed.map { CKRecord.ID(recordName: $0.name, zoneID: zone) }
        let deadline = retryDeadlineOverride
            ?? (isExtension ? AppConfig.owedRetryExtensionDeadline : AppConfig.owedRetryDeadline)
        let fetched: ZoneChanges
        do {
            // A `ZoneChanges` as the box: records found, and the gone as deletions.
            fetched = try await withDeadline(deadline) {
                let box = ZoneChanges()
                for batch in ids.chunked(into: 200) {
                    // Past the deadline the body is abandoned: no further batches.
                    try Task.checkCancellation()
                    let results = try await database.fetchRecords(batch, desiredKeys: Self.changeFetchKeys)
                    for (id, outcome) in results {
                        switch outcome {
                        case .success(let record): box.records.append(record)
                        case .failure(let error as CKError) where Self.isUnknownItem(error): box.deletedIDs.append(id)
                        case .failure: break
                        }
                    }
                }
                return box
            }
            // Out of time (a widget's deadline): nothing is filed after its caller moved on.
            try Task.checkCancellation()
        } catch {
            log.notice("Couldn't fetch owed records: \(error.localizedDescription, privacy: .public)")
            // Out of time — its own deadline or the pass's — keeps the claim, as a blind
            // try: given back, a stall would be paid again on every pass. A quick
            // failure (offline) gives it back for the next pass.
            let stalled = error is CancellationError
            await MainActor.run { self.stores.shared.noteOwedRetry(fetched: stalled) }
            return nil
        }
        let byName = Dictionary(owed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Resync misses first, grouped by the mark they kept; a receipt owed
        // incrementally then finds the moments it refers to.
        let groups = Self.retryGroups(fetched.records.map(\.recordID.recordName), owed: byName)
        let records = Dictionary(fetched.records.map { ($0.recordID.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        var merged = RefreshResult.empty
        var arrived: [Moment] = []
        var unreadable: Set<String> = []
        for group in groups {
            let changes = ZoneChanges()
            changes.records = group.names.compactMap { records[$0] }
            changes.moreComing = true
            let applied = await apply(changes, pairing: pairing, fullResync: group.resync,
                                      newsMark: group.resync ? .kept(group.mark) : .current)
            merged.absorb(applied.result)
            arrived += applied.arrived
            unreadable.formUnion(applied.result.unreadableRecordNames)
        }
        let read = Set(fetched.records.map(\.recordID.recordName)).subtracting(unreadable)
        let settled = read.union(fetched.deletedIDs.map(\.recordName))
        await MainActor.run {
            self.stores.shared.noteOwedRetry(fetched: true, readAny: !read.isEmpty)
            guard self.stores.shared.pairing?.sameZone(as: pairing) == true else { return }
            self.stores.shared.noteFetched(missed: [], settled: settled, process: self.processLabel)
        }
        if !settled.isEmpty { log.notice("Settled \(settled.count) owed record(s).") }
        return (merged, arrived)
    }

    /// The order a retry files its records in: a resync's misses first, by the mark
    /// they kept, oldest (none) first — so arrival, and the banner, don't depend on
    /// a dictionary's order — then the rest incrementally, a receipt among them
    /// finding the moments it refers to. Groups with nothing are left out.
    static func retryGroups(_ names: [String], owed: [String: SharedStore.UnreadableTally.OwedRecord])
        -> [(names: [String], resync: Bool, mark: Date?)] {
        let resync = names.filter { owed[$0]?.resync == true }
        let marks = Dictionary(grouping: resync, by: { owed[$0]?.newsAfter })
        var groups = marks.keys.sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) }
            .map { (names: marks[$0] ?? [], resync: true, mark: $0) }
        let rest = names.filter { owed[$0]?.resync != true }
        if !rest.isEmpty { groups.append((rest, false, nil)) }
        return groups
    }

    /// A reference type on purpose: accumulating into a captured `var` struct is a
    /// data race to the compiler. CloudKit calls the blocks serially, so a box is enough.
    final class ZoneChanges: @unchecked Sendable {
        var records: [CKRecord] = []
        /// Changed records the server reported but couldn't hand over: held like
        /// unreadable ones, or the token would carry the fetch past them for good.
        var failedIDs: [CKRecord.ID] = []
        var deletedIDs: [CKRecord.ID] = []
        /// The archived server change token (`CloudSync.encodeToken`).
        var token: Data?
        /// A batch stopped short; `token` continues from where it stopped.
        var moreComing = false
        /// The zone's own failure. It can arrive only here, with the operation
        /// "succeeding" — an empty delta that looked complete.
        var zoneError: Error?
    }

    /// Every field a refresh reads; assets stay out (see `fetchZoneChanges`).
    /// `IngestTests` checks every non-asset `Field` is here: one missing reads nil.
    static let changeFetchKeys: [String] = [
        Field.emoji, Field.message, Field.displayName, Field.updatedAt,
        Field.isCelebration, Field.celebrationStyle,
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
    /// Records per batch of the app's fetch: each is filed and its token kept
    /// before the next, so a slow link's resync of a long history converges.
    static let appBatchLimit = 400

    /// Whether this process is the widget or the notification service.
    static var isAppExtension: Bool { SharedStore.processLabel != "app" }

    /// Assets are excluded via `desiredKeys` — a first sync would otherwise pull
    /// every photo and recording ever sent. Media is fetched separately, on demand.
    /// A `batchLimit` returns after the first page with `moreComing` set; the page's
    /// token is a valid cursor, so applying it before persisting stays safe.
    /// A caller that needs only names and system fields passes fewer `desiredKeys`.
    func fetchZoneChanges(zone: CKRecordZone.ID,
                          in database: any CloudDatabase,
                          since previous: Data?,
                          batchLimit: Int? = nil,
                          desiredKeys: [String] = CloudSync.changeFetchKeys) async throws -> ZoneChanges {
        try await database.zoneChanges(zone: zone, since: previous, batchLimit: batchLimit, desiredKeys: desiredKeys)
    }

    /// Someone is always waiting on a fetch — a banner, a widget, the open app —
    /// so never CloudKit's default QoS, which is discretionary: on mobile data
    /// iOS held it past the notification service's deadline.
    static func changesOperation(zone: CKRecordZone.ID,
                                 since previous: CKServerChangeToken?,
                                 batchLimit: Int? = nil,
                                 desiredKeys: [String]) -> CKFetchRecordZoneChangesOperation {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: previous,
            resultsLimit: batchLimit,
            desiredKeys: desiredKeys
        )
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: configuration]
        )
        operation.fetchAllChanges = batchLimit == nil
        operation.configuration.qualityOfService = .userInitiated
        return operation
    }

    /// Files a batch of changed records into local state. The decisions are
    /// `ParsedDelta`'s (pure, tested); this performs its writes, in this order.
    /// `arrived` is every new moment, own and partner's, for `prefetchMedia`.
    /// What a full resync judges news against: the snapshot's mark, or the one an
    /// owed record kept from when it was missed.
    enum NewsMark: Sendable { case current, kept(Date?) }

    /// Whether a resync batch that missed records keeps its token rather than
    /// owing them: in a process without the keys (they'd only be missed again, and
    /// a whole zone would overflow the list); or past the room the list has left —
    /// until the app, with its keys, has looked `heldResyncGiveUpPasses` spaced
    /// times and they're still unreadable: then it moves on, owing what fits
    /// (the rest counted `abandoned`) rather than re-fetching the zone forever.
    struct ResyncHold: Sendable {
        var keysAvailable = true
        var room = AppConfig.owedRecordLimit
        var heldPasses = 0

        func holds(fullResync: Bool, missed: Int) -> Bool {
            guard fullResync, missed > 0 else { return false }
            if !keysAvailable { return true }
            return missed > room && heldPasses < AppConfig.heldResyncGiveUpPasses
        }
    }

    /// - Returns: also the mark this pass judged a resync's news against, for its misses to keep.
    func apply(_ changes: ZoneChanges,
               pairing: PairingInfo,
               fullResync: Bool = false,
               hold: ResyncHold = ResyncHold(),
               newsMark: NewsMark = .current,
               missedEarlier: Bool = false,
               readEarlier: Date? = nil) async
        -> (result: RefreshResult, arrived: [Moment], judgedNewsAfter: Date?, newestRead: Date?) {
        let store = self.stores.shared
        // One decode for every judgement below; the fold itself re-reads under the lock.
        // Reported, or deleted here and not yet gone from iCloud: neither comes back.
        let (hidden, held, owed) = await MainActor.run {
            (store.hiddenMomentIDs.union(store.pendingMomentDeletions), store.snapshot, store.unreadableTally.owed)
        }
        // Moments this phone already owes a fetch, if a resync reads them first:
        // judged as they were missed (`ParsedDelta.OwedNews`).
        let owedNews = Dictionary(owed.compactMap { entry -> (String, ParsedDelta.OwedNews)? in
            guard let id = pairing.role.other.momentID(fromRecordName: entry.name) else { return nil }
            return (id, entry.resync ? .resync(newsAfter: entry.newsAfter) : .waited)
        }, uniquingKeysWith: { first, _ in first })
        let judgedNewsAfter: Date? = {
            if case .kept(let mark) = newsMark { return mark }
            return held.newsAfter
        }()
        let names = myRecordNames(pairing)
        var metadata = recordMetadata
        metadata.isForeign = { Self.isForeign($0, names: names) }
        let parsed = ParsedDelta.parse(records: changes.records,
                                       deletedIDs: changes.deletedIDs,
                                       mineRole: pairing.role,
                                       hidden: hidden,
                                       freshStart: held.freshStart,
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
        // Another zone's copy is never used: `saveNudge` matches the record ID.
        if let ownNudge = parsed.myNudge { await cacheNudgeRecord(ownNudge) }
        if let ownStatus = parsed.myStatus,
           let server = Self.payload(from: ownStatus, nudge: nil, existing: nil, fromPartner: false) {
            await cacheStatusRecord(ownStatus, payload: server)
        }

        // Captured before the deletions and the insert below, so "new" can mean
        // "not already stored". Only when the delta touches moments: decoding 5,000
        // entries for a status or a heart is most of an extension's pass.
        let indexed = parsed.moments.isEmpty && parsed.removedMomentIDs.isEmpty ? [] : self.stores.index.load()
        let alreadyKnown = Set(indexed.map(\.id))
        // Published words only: an edit still on its way out isn't contradicted by the old copy.
        let knownCaptions = Dictionary(indexed.filter(\.captionPublished).map { ($0.id, $0.caption) },
                                       uniquingKeysWith: { first, _ in first })
        let oldestRetained = indexed.count >= AppConfig.momentHistoryLimit
            ? indexed[AppConfig.momentHistoryLimit - 1].sentAt : nil

        let removed = Set(parsed.removedMomentIDs)
        self.stores.index.remove(ids: removed)
        parsed.removedMomentIDs.forEach(self.stores.media.delete(id:))
        // A kept recap may show a picture just deleted; it's remade on the next look.
        // Only pictures this phone held — never memos, nor our own delete echoing back.
        if RecapPlan.invalidates(removed: removed, known: indexed) { self.stores.recaps.removeAll() }
        // The cloud cap pruning the oldest entries, mirrored locally.
        self.stores.statusLog.remove(fromMe: true, at: parsed.removedMyLogs)
        self.stores.statusLog.remove(fromMe: false, at: parsed.removedTheirLogs)

        let outcome = parsed.outcome(mineRole: pairing.role,
                                     previousMine: held.mine,
                                     previousTheirs: held.theirs,
                                     minePublished: held.myStatusPublished,
                                     alreadyKnown: alreadyKnown,
                                     knownCaptions: knownCaptions,
                                     ownEdits: ParsedDelta.ownEditEchoes(in: indexed),
                                     knownPartnerSentAt: Dictionary(indexed.filter { !$0.fromMe }.map { ($0.id, $0.sentAt) },
                                                                    uniquingKeysWith: { first, _ in first }),
                                     heldFreshStart: held.freshStart,
                                     hidden: hidden,
                                     oldestRetained: oldestRetained,
                                     fullResync: fullResync,
                                     newsAfter: judgedNewsAfter,
                                     owedNews: fullResync ? owedNews : [:])
        // Collages show captions: a partner's edit makes a kept recap stale.
        if outcome.result.editedPartnerMoments.contains(where: \.isPicture) { self.stores.recaps.removeAll() }
        // Bound to `let`s before crossing actors.
        // Only a complete fetch that missed nothing — in any of its batches — has
        // read everything up to its newest record: a missed one may be older, and
        // still news when read.
        let missedAny = missedEarlier || !parsed.unreadable.isEmpty || !changes.failedIDs.isEmpty
        let complete = !changes.moreComing
            && !hold.holds(fullResync: fullResync, missed: parsed.unreadable.count + changes.failedIDs.count)
        let fold = {
            var fold = outcome.fold
            // The newest any batch read: a sweep's last page can hold nothing readable.
            let newest = [readEarlier, parsed.newestReadSavedAt].compactMap { $0 }.max()
            fold.readUpTo = complete && !missedAny ? newest : nil
            return fold
        }()

        let snapshotChanged = await MainActor.run {
            var changed = false
            store.mutate(reloadWidgets: false) {
                // Checked *inside* the locked mutate, by zone identity: an unlink
                // — or an unlink and a new pairing — can land mid-refresh, and
                // writing this delta would file the ex's records onto the wrong snapshot.
                guard store.pairing?.sameZone(as: pairing) == true else { return }
                let before = $0
                fold.fold(into: &$0)
                $0.isPaired = true
                changed = $0 != before
                // Only a complete fetch counts as synced: the widget skips its own
                // fetch after a recent sync, and one batch of a large delta isn't one.
                if complete { $0.lastSyncedAt = Date() }
            }
            return changed
        }

        // An unlink can land mid-refresh (the status write above checks under the
        // lock); past this point nothing from the ex's zone may be filed either.
        guard await MainActor.run(body: { store.pairing?.sameZone(as: pairing) == true }) else {
            return (.empty, [], judgedNewsAfter, nil)
        }

        if let theirs = outcome.partnerStatusToLog { self.stores.statusLog.record(theirs, fromMe: false) }
        if let mine = outcome.myStatusToLog { self.stores.statusLog.record(mine, fromMe: true) }
        // The durable log: one entry per `StatusLog` record, same dedup key as the
        // two lines above, so a status and its log record collapse into one.
        // Re-judged inside each store's lock against the epoch as it is then.
        let created = Self.serverCreationTimes(changes.records, mineRole: pairing.role)
        self.stores.statusLog.record(parsed.logEntries) {
            let epoch = self.stores.shared.snapshot.freshStart.clearedBefore
            let isCleared = FreshStartPolicy.clearedFilter(createdAt: created.logs, epoch: epoch)
            return { isCleared(FreshStartPolicy.LogKey(fromMe: $0.fromMe, at: $0.at)) }
        }

        let arrived = outcome.arrived
        if arrived.isEmpty {
            if !parsed.removedMomentIDs.isEmpty {
                // A deletions-only delta still invalidates snapshot fields derived from
                // the index — otherwise the photo widget points at deleted files.
                let index = stores.index
                await MainActor.run { _ = store.refreshDerived(index: index) }
            } else if snapshotChanged {
                // An empty delta reloads nothing: each reload costs every widget kind budget.
                store.requestWidgetReload()
            }
        } else {
            // Off the main actor: an index rewrite, a snapshot write and a media
            // prune, all thread-safe, mustn't stall the app's UI per arriving moment.
            store.record(arrived, cleared: {
                let epoch = store.snapshot.freshStart.clearedBefore
                let isCleared = FreshStartPolicy.clearedFilter(createdAt: created.moments, epoch: epoch)
                return { isCleared($0.id) }
            }, index: stores.index, media: stores.media)
        }

        // After the moments above are in the index — a receipt arriving in the
        // same delta (a full resync) must find the entries it refers to.
        if let receipts = parsed.theirReceipts {
            self.stores.index.applyPartnerReceipts(Self.receiptMap(from: receipts))
        }
        return (outcome.result, arrived, judgedNewsAfter, parsed.newestReadSavedAt)
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
        let store = self.stores.media
        let process = Self.prefetchProcess
        let recent = process == .app ? Array(self.stores.index.load().prefix(MediaPrefetchPlan.appLimit)) : []
        // A kind from a newer build has no media this build knows to fetch.
        let items = MediaPrefetchPlan.items(for: arrived.filter(\.kind.isSupported),
                                            recent: recent.filter(\.kind.isSupported), in: process,
                                            hasMedia: store.hasMedia,
                                            hasThumbnail: { store.hasThumbnail(for: $0.id) })
        guard !items.isEmpty else { return }
        let samePairing = { await MainActor.run { self.stores.shared.pairing?.sameZone(as: pairing) == true } }
        // One batched fetch per kind of file, not one per moment.
        for fetch in [MediaPrefetchPlan.Fetch.thumbnail, .full] {
            let moments = items.filter { $0.fetch == fetch }.map(\.moment)
            guard !moments.isEmpty else { continue }
            guard !Task.isCancelled, await samePairing() else { break }
            do {
                if process == .app {
                    try await download(fetch, for: moments, pairing: pairing, in: database(for: pairing))
                } else {
                    // Extensions are inside a budget (the banner's, the timeline's):
                    // a stalled fetch gives up rather than eat it.
                    try await withDeadline(AppConfig.widgetDeadline) {
                        try await self.download(fetch, for: moments, pairing: pairing, in: self.database(for: pairing))
                    }
                }
            } catch {
                log.notice("Media prefetch stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Landed after an unlink's wipe: not this pairing's any more.
        guard await samePairing() else {
            items.forEach { store.delete(id: $0.moment.id) }
            return
        }
        SharedStore.reloadWidgets()
    }
}
