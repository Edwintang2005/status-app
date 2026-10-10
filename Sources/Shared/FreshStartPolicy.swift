import Foundation

/// The fresh start's decisions, pure so they run under `make test`: which
/// record writes are allowed, when both sides have committed, what this
/// device does next, and what its clear deletes — in the zone and locally.
///
/// The handshake: one side asks (its record's server save time is the epoch),
/// the other agrees naming that epoch, the asker commits on seeing it, and only
/// then does each phone clear — its own records from the zone, and its own copy.
/// The commit is the one point a withdraw can't race: both are writes to the
/// asker's own record, judged against the server copy.
enum FreshStartPolicy {
    // MARK: - Writes to our own record

    enum Transition: Equatable {
        case write(FreshStartRecord)
        case unchanged(FreshStartRecord?)
        case refused(FreshStartRecord?)
    }

    /// What `intent` makes of our record as the server holds it. The same rule
    /// runs on the local copy (`FreshStart.begin`) and on the fetched server copy.
    /// `partner` is their record where it's known: an ask never replaces our
    /// yes to an ask of theirs that still stands.
    static func transition(_ intent: FreshStartIntent,
                           from current: FreshStartRecord?,
                           partner: FreshStartRecord? = nil) -> Transition {
        let cleared = current?.clearedBefore
        // A commit not yet cleared: nothing may replace it until it's done.
        let clearing = current.map { $0.stage == .committed && !isDone($0.epoch, $0.clearedBefore) } ?? false
        func stage(_ stage: FreshStartRecord.Stage, _ epoch: Date) -> Bool {
            current?.stage == stage && current?.epoch == epoch
        }

        switch intent {
        case .ask:
            if current?.stage == .asking { return .unchanged(current) }
            if clearing { return .refused(current) }
            if let current, current.stage == .agreeing, let agreed = current.epoch,
               !isDone(agreed, current.clearedBefore), partner?.epoch == agreed,
               partner?.stage == .asking || partner?.stage == .committed {
                return .refused(current)
            }
            return .write(FreshStartRecord(stage: .asking, clearedBefore: cleared))
        case .agree(let epoch):
            if stage(.agreeing, epoch) || stage(.committed, epoch) { return .unchanged(current) }
            if clearing { return .refused(current) }
            return .write(FreshStartRecord(stage: .agreeing, epoch: epoch, clearedBefore: cleared))
        case .convert(let epoch):
            if stage(.agreeing, epoch) { return .unchanged(current) }
            // Only a standing ask converts; a withdrawn one consents to nothing.
            guard current?.stage == .asking else { return .refused(current) }
            return .write(FreshStartRecord(stage: .agreeing, epoch: epoch, clearedBefore: cleared))
        case .commit(let epoch):
            if stage(.committed, epoch) { return .unchanged(current) }
            guard stage(.asking, epoch) else { return .refused(current) }
            return .write(FreshStartRecord(stage: .committed, epoch: epoch, clearedBefore: cleared))
        case .withdraw:
            guard let current, current.stage != .idle else { return .unchanged(current) }
            // Agreements are final, and a commit has already started both phones.
            guard current.stage == .asking else { return .refused(current) }
            return .write(FreshStartRecord(stage: .idle, clearedBefore: cleared))
        case .complete(let epoch):
            let newCleared = max(cleared ?? .distantPast, epoch)
            // Never re-save an ask: its save time *is* its epoch.
            if current?.stage == .asking { return .unchanged(current) }
            if current?.stage == .idle, isDone(epoch, cleared) { return .unchanged(current) }
            // A later round already under way keeps its stage.
            if let current, current.stage != .idle, let later = current.epoch, later > epoch {
                return .write(FreshStartRecord(stage: current.stage, epoch: later, clearedBefore: newCleared))
            }
            return .write(FreshStartRecord(stage: .idle, clearedBefore: newCleared))
        }
    }

    private static func isDone(_ epoch: Date?, _ cleared: Date?) -> Bool {
        guard let epoch else { return true }
        return epoch <= (cleared ?? .distantPast)
    }

    // MARK: - Agreement

    /// The side consents to clearing before `epoch`: agreed or committed to it, or already cleared it.
    static func consents(_ record: FreshStartRecord?, to epoch: Date) -> Bool {
        guard let record else { return false }
        return ((record.stage == .agreeing || record.stage == .committed) && record.epoch == epoch)
            || record.clearedBefore == epoch
    }

    /// The side committed to `epoch` (a side only clears what was committed).
    static func commits(_ record: FreshStartRecord?, to epoch: Date) -> Bool {
        guard let record else { return false }
        return (record.stage == .committed && record.epoch == epoch) || record.clearedBefore == epoch
    }

    /// The newest epoch one side committed to and the other consents to. Exact
    /// match only: an agreement naming a withdrawn or older ask does nothing.
    static func committedEpoch(mine: FreshStartRecord?, theirs: FreshStartRecord?) -> Date? {
        [mine?.epoch, mine?.clearedBefore, theirs?.epoch, theirs?.clearedBefore]
            .compactMap { $0 }
            .filter { isCommitted($0, mine: mine, theirs: theirs) }
            .max()
    }

    static func isCommitted(_ epoch: Date, mine: FreshStartRecord?, theirs: FreshStartRecord?) -> Bool {
        (commits(mine, to: epoch) && consents(theirs, to: epoch))
            || (commits(theirs, to: epoch) && consents(mine, to: epoch))
    }

    /// The partner's ask, while it stands and isn't one this device already cleared.
    static func standingAsk(_ record: FreshStartRecord?, finishedBefore: Date?) -> Date? {
        guard let record, record.stage == .asking, let epoch = record.epoch,
              !isDone(epoch, record.clearedBefore), !isDone(epoch, finishedBefore) else { return nil }
        return epoch
    }

    // MARK: - Where it stands

    enum Phase: Equatable, Sendable {
        case idle(lastCleared: Date?)
        /// Our ask stands; nothing happens until they agree. Withdrawable.
        case asked(Date?)
        /// Their ask stands, unanswered here.
        case theyAsked(Date)
        /// We agreed (or both asked); their phone commits next time it's open.
        case agreed(Date)
        /// They agreed to our ask; this phone commits on its next pass.
        case starting(Date)
        /// Committed; this device's clear hasn't finished.
        case clearing(Date)
        /// Our side is cleared; theirs hasn't said so yet.
        case waitingForPartner(Date)
    }

    static func phase(_ state: FreshStart, role: PairRole) -> Phase {
        let finished = state.finishedBefore
        if let epoch = committedEpoch(mine: state.mine, theirs: state.theirs), !isDone(epoch, finished) {
            return .clearing(epoch)
        }
        let mine = state.mine
        let myAsk = mine?.stage == .asking && !isDone(mine?.epoch, mine?.clearedBefore)
        if let theirs = standingAsk(state.theirs, finishedBefore: finished) {
            if consents(mine, to: theirs) { return .agreed(theirs) }
            if myAsk, let ours = mine?.epoch {
                return yields(ours, to: theirs, role: role) ? .agreed(theirs) : .asked(ours)
            }
            return .theyAsked(theirs)
        }
        if mine?.stage == .asking {
            if let ours = mine?.epoch, consents(state.theirs, to: ours) { return .starting(ours) }
            return .asked(mine?.epoch)
        }
        if let epoch = finished, !(state.theirs?.clearedBefore.map { $0 >= epoch } ?? false),
           committedEpoch(mine: mine, theirs: state.theirs) == epoch {
            return .waitingForPartner(epoch)
        }
        return .idle(lastCleared: finished)
    }

    /// Both asked: the later ask yields to the earlier — consenting to clear
    /// before a time consents to clearing before any earlier one. A tie goes to the owner.
    static func yields(_ ours: Date, to theirs: Date, role: PairRole) -> Bool {
        theirs < ours || (theirs == ours && role == .participant)
    }

    // MARK: - What this device does next

    enum Step: Equatable, Sendable {
        case publish(FreshStartIntent)
        case clear(Date)
    }

    /// One step at a time, app only: extensions never write or delete here.
    static func nextStep(_ state: FreshStart, role: PairRole) -> Step? {
        if let intent = state.pendingIntent { return .publish(intent) }
        if let mine = state.mine, mine.stage == .asking, let ours = mine.epoch,
           !isDone(ours, mine.clearedBefore) {
            if state.theirs?.stage == .agreeing, state.theirs?.epoch == ours { return .publish(.commit(ours)) }
            if let theirs = standingAsk(state.theirs, finishedBefore: state.finishedBefore),
               yields(ours, to: theirs, role: role) {
                return .publish(.convert(theirs))
            }
        }
        if let epoch = committedEpoch(mine: state.mine, theirs: state.theirs), !isDone(epoch, state.finishedBefore) {
            return .clear(epoch)
        }
        return nil
    }

    // MARK: - The clear

    /// A status log entry's identity: side and whole second, like its record name.
    struct LogKey: Hashable, Sendable {
        var fromMe: Bool
        var seconds: Int

        init(fromMe: Bool, at date: Date) {
            self.fromMe = fromMe
            self.seconds = date.wholeSecondsSince1970 ?? 0
        }
    }

    /// The zone at clear time, classified by server creation time against the epoch.
    struct Zone: Equatable, Sendable {
        var momentsBefore: Set<String> = []
        var momentsAfter: Set<String> = []
        var logsBefore: Set<LogKey> = []
        var logsAfter: Set<LogKey> = []
    }

    struct ZoneItem: Sendable {
        var recordName: String
        /// Server creation time; `nil` is never deleted.
        var createdAt: Date?
    }

    struct ZonePlan: Equatable, Sendable {
        var deletions: [String] = []
        var zone = Zone()
    }

    /// Our own history records created before the epoch, minus the log record
    /// of the status still showing (both statuses carry on). The receipt goes
    /// whole: it's republished from what's left.
    static func zonePlan(_ items: [ZoneItem],
                         role: PairRole,
                         epoch: Date,
                         keepingStatusLogAt keep: Date?) -> ZonePlan {
        var plan = ZonePlan()
        let spared = keep.map { role.statusLogRecordName(at: $0) }
        for item in items {
            let name = item.recordName
            let before = item.createdAt.map { $0 < epoch }
            for side in [role, role.other] {
                if let id = side.momentID(fromRecordName: name) {
                    if before == true { plan.zone.momentsBefore.insert(id) } else { plan.zone.momentsAfter.insert(id) }
                }
                if let date = side.statusLogDate(fromRecordName: name) {
                    let key = LogKey(fromMe: side == role, at: date)
                    if before == true { plan.zone.logsBefore.insert(key) } else { plan.zone.logsAfter.insert(key) }
                }
            }
            guard ZoneClearPlan.deletes(name, role: role, scope: .freshStart), name != spared else { continue }
            if name == role.receiptRecordName || before == true {
                plan.deletions.append(name)
            }
        }
        return plan
    }

    /// What a delta's records may still file, judged by each one's server
    /// creation time against the epoch read *now* — under the store's lock, so
    /// a commit another process folded after this delta was parsed still counts.
    static func clearedFilter<Key: Hashable>(createdAt: [Key: Date], epoch: Date?) -> (Key) -> Bool {
        guard let epoch else { return { _ in false } }
        return { key in createdAt[key].map { $0 < epoch } ?? false }
    }

    struct Purge: Equatable, Sendable {
        var momentIDs: [String] = []
        var myLogs: [Date] = []
        var theirLogs: [Date] = []
    }

    /// What leaves this device's own copy. The zone decides wherever it can
    /// (server time on both sides of the epoch); what it doesn't hold is judged
    /// by its own date — except an own send that never reached iCloud, which is
    /// the only copy: it's kept and sent, and lands after the epoch like
    /// anything else sent then.
    static func purge(moments: [Moment],
                      log: [StatusHistoryEntry],
                      zone: Zone,
                      epoch: Date,
                      keeping: Set<LogKey>) -> Purge {
        var purge = Purge()
        for moment in moments {
            if zone.momentsBefore.contains(moment.id) {
                purge.momentIDs.append(moment.id)
            } else if zone.momentsAfter.contains(moment.id) || (moment.fromMe && !moment.uploaded) {
                continue
            } else if moment.sentAt < epoch {
                purge.momentIDs.append(moment.id)
            }
        }
        for entry in log {
            let key = LogKey(fromMe: entry.fromMe, at: entry.at)
            guard !keeping.contains(key), !zone.logsAfter.contains(key) else { continue }
            if zone.logsBefore.contains(key) || entry.at < epoch {
                if entry.fromMe { purge.myLogs.append(entry.at) } else { purge.theirLogs.append(entry.at) }
            }
        }
        return purge
    }
}
