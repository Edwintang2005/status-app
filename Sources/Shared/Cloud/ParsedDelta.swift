import CloudKit

/// The server's own facts about a record — injectable, since a `CKRecord` built
/// in a test has no server dates or author.
struct RecordMetadata: Sendable {
    /// When the record first reached the server.
    var createdAt: @Sendable (CKRecord) -> Date?
    /// Its last save.
    var savedAt: @Sendable (CKRecord) -> Date?
    /// Positively written by another iCloud account than this one.
    var isForeign: @Sendable (CKRecord) -> Bool
    /// Creation only, no fallback: a counter's identity (`Snapshot.partnerNudgeCreatedAt`).
    var firstSavedAt: @Sendable (CKRecord) -> Date? = { $0.creationDate }

    static let server = RecordMetadata(createdAt: { $0.creationDate ?? $0.modificationDate },
                                       savedAt: { $0.modificationDate },
                                       isForeign: { _ in false })
}

/// One fetched delta sorted into what `CloudSync.apply` files, then judged
/// against the held snapshot. Pure — no stores, no network — so the rules
/// (unreadable holds, reported moments, deletions by role, delete-then-recreate,
/// what counts as new or as our own write) run under `make test`. `apply` only
/// performs the writes this describes.
struct ParsedDelta {
    var myStatus: CKRecord?
    var theirStatus: CKRecord?
    var myNudge: CKRecord?
    var theirNudge: CKRecord?
    var theirReceipts: CKRecord?
    /// The status records' server save times — how the partner's copies are ordered.
    var myStatusSavedAt: Date?
    var theirStatusSavedAt: Date?
    /// When the partner's nudge counter was created: a new one restarts at 1.
    var theirNudgeCreatedAt: Date?
    /// The partner's nudge counter was deleted (an unlink on their side).
    var theirNudgeErased = false
    var anniversaryRecord: CKRecord?
    var requestRecord: CKRecord?
    /// Readable moments; reported ones (`hidden`) are already dropped — the
    /// record lives on in the sender's iCloud and every resync re-delivers it.
    var moments: [Moment] = []
    var logEntries: [StatusHistoryEntry] = []
    /// Records whose encrypted fields came back empty (invariant 2).
    var unreadable: [String] = []
    /// The partner's unreadable moments, parsed from plaintext only — for the
    /// banner's wording, never filed into the index.
    var heldMoments: [Moment] = []
    /// The partner deleting their status record is how a participant unlinks.
    var partnerErased = false
    var anniversaryErased = false
    var requestErased = false
    /// Moment IDs whose records were deleted, under either role's name.
    var removedMomentIDs: [String] = []
    /// `StatusLog` records the cloud cap pruned, by side.
    var removedMyLogs: [Date] = []
    var removedTheirLogs: [Date] = []
    /// Both sides' `FreshStart` records, readable ones only.
    var freshStart = FreshStart.Incoming()
    /// Our own `FreshStart` record arrived written by another account: ignored.
    var foreignFreshStart = false
    /// Moments and log records created before the committed epoch: doomed, so never filed.
    var beforeEpoch = 0

    /// `freshStart` is what's held before this delta: its committed epoch, moved
    /// by any `FreshStart` record in the delta itself, keeps older history out —
    /// a full resync carries the commit and the records it clears together.
    static func parse(records: [CKRecord],
                      deletedIDs: [CKRecord.ID],
                      mineRole: PairRole,
                      hidden: Set<String>,
                      freshStart held: FreshStart? = nil,
                      metadata: RecordMetadata = .server) -> ParsedDelta {
        let theirsRole = mineRole.other
        var delta = ParsedDelta()

        for record in records where record.recordType == CloudSync.RecordType.freshStart && CloudSync.isReadable(record) {
            let name = record.recordID.recordName
            guard let parsed = CloudSync.freshStart(from: record, savedAt: metadata.savedAt(record)) else { continue }
            if name == mineRole.freshStartRecordName {
                // The share is read-write for both: a copy of ours the partner
                // wrote must not stand in for our own consent.
                if metadata.isForeign(record) {
                    delta.foreignFreshStart = true
                } else {
                    delta.freshStart.mine = parsed
                }
            } else if name == theirsRole.freshStartRecordName {
                delta.freshStart.theirs = parsed
            }
        }
        for recordID in deletedIDs {
            if recordID.recordName == mineRole.freshStartRecordName, delta.freshStart.mine == nil {
                delta.freshStart.mineErased = true
            }
            if recordID.recordName == theirsRole.freshStartRecordName, delta.freshStart.theirs == nil {
                delta.freshStart.theirsErased = true
            }
        }
        var projected = held
        projected?.fold(delta.freshStart)
        let epoch = projected?.clearedBefore

        for record in records {
            let name = record.recordID.recordName
            // Checked before readability: a doomed record must not hold the token either.
            if let epoch,
               record.recordType == CloudSync.RecordType.moment || record.recordType == CloudSync.RecordType.statusLog,
               let created = metadata.createdAt(record), created < epoch {
                delta.beforeEpoch += 1
                continue
            }
            // Every type below always carries its probe field; an empty one means
            // the process couldn't decrypt, and the record is left for a later fetch.
            guard CloudSync.isReadable(record) else {
                delta.unreadable.append(name)
                if record.recordType == CloudSync.RecordType.moment,
                   let moment = CloudSync.moment(from: record, mineRole: mineRole, theirsRole: theirsRole),
                   !moment.fromMe {
                    delta.heldMoments.append(moment)
                }
                continue
            }
            switch record.recordType {
            case CloudSync.RecordType.status:
                if name == mineRole.statusRecordName {
                    delta.myStatus = record
                    delta.myStatusSavedAt = metadata.savedAt(record)
                }
                if name == theirsRole.statusRecordName {
                    delta.theirStatus = record
                    delta.theirStatusSavedAt = metadata.savedAt(record)
                }
            case CloudSync.RecordType.nudge:
                if name == mineRole.nudgeRecordName { delta.myNudge = record }
                if name == theirsRole.nudgeRecordName {
                    delta.theirNudge = record
                    delta.theirNudgeCreatedAt = metadata.firstSavedAt(record)
                        .flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
                        .map { $0.wholeSeconds }
                }
            case CloudSync.RecordType.receipt:
                if name == theirsRole.receiptRecordName { delta.theirReceipts = record }
            case CloudSync.RecordType.anniversary:
                if name == CloudSync.anniversaryRecordName { delta.anniversaryRecord = record }
            case CloudSync.RecordType.anniversaryRequest:
                if name == CloudSync.anniversaryRequestRecordName { delta.requestRecord = record }
            case CloudSync.RecordType.moment:
                if let moment = CloudSync.moment(from: record, mineRole: mineRole, theirsRole: theirsRole),
                   !hidden.contains(moment.id) {
                    delta.moments.append(moment)
                }
            case CloudSync.RecordType.statusLog:
                if let entry = CloudSync.logEntry(from: record, mineRole: mineRole, theirsRole: theirsRole) {
                    delta.logEntries.append(entry)
                }
            default:
                break
            }
        }

        for recordID in deletedIDs {
            let name = recordID.recordName
            if name == theirsRole.statusRecordName { delta.partnerErased = true }
            if name == theirsRole.nudgeRecordName { delta.theirNudgeErased = true }
            if name == CloudSync.anniversaryRecordName { delta.anniversaryErased = true }
            if name == CloudSync.anniversaryRequestRecordName { delta.requestErased = true }
            if let id = mineRole.momentID(fromRecordName: name) ?? theirsRole.momentID(fromRecordName: name),
               CloudSync.isSafeMomentID(id) {
                delta.removedMomentIDs.append(id)
            }
            if let date = mineRole.statusLogDate(fromRecordName: name) {
                delta.removedMyLogs.append(date)
            } else if let date = theirsRole.statusLogDate(fromRecordName: name) {
                delta.removedTheirLogs.append(date)
            }
        }
        // A delete and a recreation can share one delta; the record that exists now wins.
        if delta.theirStatus != nil { delta.partnerErased = false }
        if delta.theirNudge != nil { delta.theirNudgeErased = false }
        if delta.anniversaryRecord != nil { delta.anniversaryErased = false }
        if delta.requestRecord != nil { delta.requestErased = false }
        return delta
    }

    /// What the delta means against what this device held before it.
    struct Outcome {
        /// Folded into `Snapshot` inside the locked mutate.
        var fold: RefreshDelta
        /// Status changes for the history log (which dedups by `(fromMe, wordsAt)`).
        var partnerStatusToLog: StatusPayload?
        var myStatusToLog: StatusPayload?
        /// Moments to file, oldest first.
        var arrived: [Moment]
        var result: RefreshResult
    }

    /// `alreadyKnown` is the index's IDs captured *before* this delta is filed,
    /// so "new" means not already stored — a full resync re-delivers everything.
    /// `oldestRetained` is the index's oldest kept `sentAt` once it's at its
    /// cap: an unknown moment older than that is history past the cap, not
    /// news, and would be trimmed straight back out. `fullResync` (no token)
    /// with `announcedFloor` keeps re-fetched history from being announced.
    func outcome(mineRole: PairRole,
                 previousMine: StatusPayload?,
                 previousTheirs: StatusPayload?,
                 minePublished: Bool,
                 alreadyKnown: Set<String>,
                 hidden: Set<String>,
                 oldestRetained: Date? = nil,
                 fullResync: Bool = false,
                 announcedFloor: Date? = nil,
                 now: Date = Date()) -> Outcome {
        // A status record and its nudge counter arrive independently; fold
        // each into what was already known.
        let mine = CloudSync.payload(from: myStatus, nudge: myNudge, existing: previousMine,
                                     fromPartner: false, savedAt: myStatusSavedAt)
        let theirs = partnerErased ? nil : CloudSync.payload(from: theirStatus, nudge: theirNudge,
                                                             existing: previousTheirs, savedAt: theirStatusSavedAt)
        let pastCap = { (moment: Moment) in
            !alreadyKnown.contains(moment.id) && (oldestRetained.map { moment.sentAt < $0 } ?? false)
        }
        let unknown = moments.filter { !alreadyKnown.contains($0.id) && !pastCap($0) }
        // Our own records moved on the server — another device on this iCloud
        // account did it. Judged against what was held, not "arrived": a full
        // resync re-delivers everything and changes nothing. An unpublished
        // local edit legitimately differs from the server copy, so it doesn't count.
        let ownRecordsChanged = (myStatus != nil && minePublished && mine?.updatedAt != previousMine?.updatedAt)
            || (myNudge != nil && mine?.nudgeCount != previousMine?.nudgeCount)
            || (!fullResync && unknown.contains { $0.fromMe })

        let fold = RefreshDelta(
            mine: mine,
            theirs: theirs,
            partnerErased: partnerErased,
            anniversary: anniversaryRecord.flatMap { CloudSync.anniversary(from: $0, now: now) },
            anniversaryErased: anniversaryErased,
            receiptReadable: theirReceipts != nil,
            statusSeen: theirReceipts.flatMap(CloudSync.statusSeen(from:)),
            anniversaryRequestedAt: requestRecord.flatMap(CloudSync.anniversaryRequestDate(from:)),
            anniversaryRequestErased: requestErased,
            freshStart: freshStart,
            unreadableRecords: unreadable.count,
            partnerNudgeCreatedAt: partnerErased ? nil : theirNudgeCreatedAt,
            partnerNudgeErased: theirNudgeErased && !partnerErased
        )

        // Gated on the status *record* changing (not a nudge-only delta). A
        // rename restamps the record without changing the status; the sender
        // writes no `StatusLog` for it, and neither does this side.
        var partnerToLog: StatusPayload?
        if let theirs, theirStatus != nil, !partnerErased,
           !(previousTheirs.map { $0.emoji == theirs.emoji && $0.message == theirs.message
                                   && $0.isCelebration == theirs.isCelebration } ?? false) {
            partnerToLog = theirs
        }
        // Own statuses set on this device are logged at set time; this catches
        // ones written by another device on the same account. Not the echo of a
        // rename: same words, new stamp, would log twice.
        var myToLog: StatusPayload?
        if let mine, myStatus != nil, !(previousMine.map { $0.sameWords(as: mine) } ?? false) {
            myToLog = mine
        }

        let arrived = moments.filter { !pastCap($0) }.sorted { $0.sentAt < $1.sentAt }
        let isNews = { (moment: Moment) in
            !alreadyKnown.contains(moment.id) && !pastCap(moment)
                && AnnouncementPolicy.isNews(moment, fullResync: fullResync, floor: announcedFloor, now: now)
        }
        let newFromPartner = arrived.filter { !$0.fromMe && isNews($0) }
        // Same "new" test: a resync re-delivering history unreadable is not news.
        let heldKinds = heldMoments
            .filter { isNews($0) && !hidden.contains($0.id) }
            .sorted { $0.sentAt < $1.sentAt }
            .map(\.kind)

        var result = RefreshResult(partnerStatus: partnerErased ? nil : (theirs ?? previousTheirs),
                                   newPartnerMoments: newFromPartner,
                                   unreadableRecordNames: unreadable,
                                   ownRecordsChanged: ownRecordsChanged,
                                   heldPartnerMomentKinds: heldKinds,
                                   heldPartnerStatus: unreadable.contains(mineRole.other.statusRecordName))
        result.removedMoments = removedMomentIDs.count
        result.fullResync = fullResync
        result.partnerLeft = partnerErased
        return Outcome(fold: fold,
                       partnerStatusToLog: partnerToLog,
                       myStatusToLog: myToLog,
                       arrived: arrived,
                       result: result)
    }
}
