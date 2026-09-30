import CloudKit

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

    static func parse(records: [CKRecord],
                      deletedIDs: [CKRecord.ID],
                      mineRole: PairRole,
                      hidden: Set<String>) -> ParsedDelta {
        let theirsRole = mineRole.other
        var delta = ParsedDelta()

        for record in records {
            let name = record.recordID.recordName
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
                if name == mineRole.statusRecordName { delta.myStatus = record }
                if name == theirsRole.statusRecordName { delta.theirStatus = record }
            case CloudSync.RecordType.nudge:
                if name == mineRole.nudgeRecordName { delta.myNudge = record }
                if name == theirsRole.nudgeRecordName { delta.theirNudge = record }
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
    func outcome(mineRole: PairRole,
                 previousMine: StatusPayload?,
                 previousTheirs: StatusPayload?,
                 minePublished: Bool,
                 alreadyKnown: Set<String>,
                 hidden: Set<String>) -> Outcome {
        // A status record and its nudge counter arrive independently; fold
        // each into what was already known.
        let mine = CloudSync.payload(from: myStatus, nudge: myNudge, existing: previousMine, fromPartner: false)
        let theirs = partnerErased ? nil : CloudSync.payload(from: theirStatus, nudge: theirNudge,
                                                             existing: previousTheirs)
        // Our own records moved on the server — another device on this iCloud
        // account did it. Judged against what was held, not "arrived": a full
        // resync re-delivers everything and changes nothing. An unpublished
        // local edit legitimately differs from the server copy, so it doesn't count.
        let ownRecordsChanged = (myStatus != nil && minePublished && mine?.updatedAt != previousMine?.updatedAt)
            || (myNudge != nil && mine?.nudgeCount != previousMine?.nudgeCount)
            || moments.contains { $0.fromMe && !alreadyKnown.contains($0.id) }

        let fold = RefreshDelta(
            mine: mine,
            theirs: theirs,
            partnerErased: partnerErased,
            anniversary: anniversaryRecord.flatMap(CloudSync.anniversary(from:)),
            anniversaryErased: anniversaryErased,
            receiptReadable: theirReceipts != nil,
            statusSeen: theirReceipts.flatMap(CloudSync.statusSeen(from:)),
            anniversaryRequestedAt: requestRecord.flatMap(CloudSync.anniversaryRequestDate(from:)),
            anniversaryRequestErased: requestErased,
            unreadableRecords: unreadable.count
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

        let arrived = moments.sorted { $0.sentAt < $1.sentAt }
        let newFromPartner = arrived.filter { !$0.fromMe && !alreadyKnown.contains($0.id) }
        // Same "new" test: a resync re-delivering history unreadable is not news.
        let heldKinds = heldMoments
            .filter { !alreadyKnown.contains($0.id) && !hidden.contains($0.id) }
            .sorted { $0.sentAt < $1.sentAt }
            .map(\.kind)

        let result = RefreshResult(partnerStatus: partnerErased ? nil : (theirs ?? previousTheirs),
                                   newPartnerMoments: newFromPartner,
                                   unreadableRecordNames: unreadable,
                                   ownRecordsChanged: ownRecordsChanged,
                                   heldPartnerMomentKinds: heldKinds,
                                   heldPartnerStatus: unreadable.contains(mineRole.other.statusRecordName))
        return Outcome(fold: fold,
                       partnerStatusToLog: partnerToLog,
                       myStatusToLog: myToLog,
                       arrived: arrived,
                       result: result)
    }
}
