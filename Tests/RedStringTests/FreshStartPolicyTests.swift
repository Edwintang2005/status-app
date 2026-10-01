import XCTest

/// The fresh start's handshake and clear, pure: which writes the server copy
/// allows, when both sides have committed, each phone's next step, and what a
/// clear deletes in the zone and here. Epochs are server times throughout.
final class FreshStartPolicyTests: XCTestCase {
    private typealias Record = FreshStartRecord
    private let epoch = Fixtures.date(1_000)
    private let later = Fixtures.date(2_000)

    private func asking(_ at: Date, cleared: Date? = nil) -> Record { Record(stage: .asking, epoch: at, clearedBefore: cleared) }
    private func agreeing(_ at: Date, cleared: Date? = nil) -> Record { Record(stage: .agreeing, epoch: at, clearedBefore: cleared) }
    private func committed(_ at: Date, cleared: Date? = nil) -> Record { Record(stage: .committed, epoch: at, clearedBefore: cleared) }
    private func idle(cleared: Date? = nil) -> Record { Record(stage: .idle, clearedBefore: cleared) }

    private func state(mine: Record?, theirs: Record?, pending: FreshStartIntent? = nil,
                       finished: Date? = nil) -> FreshStart {
        var state = FreshStart()
        state.mine = mine
        state.theirs = theirs
        state.pendingIntent = pending
        state.finishedBefore = finished
        return state
    }

    // MARK: Writes to our own record

    func testAnAskIsWrittenOnceAndNeverResaved() {
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: nil), .write(Record(stage: .asking)))
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: idle(cleared: epoch)),
                       .write(Record(stage: .asking, clearedBefore: epoch)), "the last clear's mark carries over")
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: asking(epoch)), .unchanged(asking(epoch)),
                       "re-saving an ask would move its epoch")
        XCTAssertEqual(FreshStartPolicy.transition(.complete(epoch), from: asking(later)), .unchanged(asking(later)))
    }

    /// The linearisation point: a withdraw and a commit are both writes to the
    /// asker's record, so whichever the server takes first wins.
    func testWithdrawAndCommitCantBothLand() {
        XCTAssertEqual(FreshStartPolicy.transition(.withdraw, from: asking(epoch)), .write(idle()))
        XCTAssertEqual(FreshStartPolicy.transition(.commit(epoch), from: idle()), .refused(idle()),
                       "a withdrawn ask can't be committed")
        XCTAssertEqual(FreshStartPolicy.transition(.commit(epoch), from: asking(epoch)), .write(committed(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.withdraw, from: committed(epoch)), .refused(committed(epoch)),
                       "committed: both phones are clearing")
        XCTAssertEqual(FreshStartPolicy.transition(.commit(epoch), from: asking(later)), .refused(asking(later)),
                       "a commit names exactly the ask it saw agreed")
    }

    func testAgreementIsFinalAndOnlyAStandingAskConverts() {
        XCTAssertEqual(FreshStartPolicy.transition(.withdraw, from: agreeing(epoch)), .refused(agreeing(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.agree(epoch), from: nil), .write(agreeing(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.agree(epoch), from: agreeing(epoch)), .unchanged(agreeing(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.agree(later), from: committed(epoch)), .refused(committed(epoch)),
                       "nothing replaces a commit still clearing")
        XCTAssertEqual(FreshStartPolicy.transition(.convert(epoch), from: asking(later)), .write(agreeing(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.convert(epoch), from: idle()), .refused(idle()),
                       "a withdrawn ask consents to nothing")
    }

    /// Our yes is final while their ask stands; to an ask they withdrew it's
    /// stale, and asking ourselves replaces it.
    func testAnAskNeverReplacesALiveAgreement() {
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: agreeing(epoch), partner: asking(epoch)), .refused(agreeing(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: agreeing(epoch), partner: committed(epoch)), .refused(agreeing(epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: agreeing(epoch), partner: idle()),
                       .write(Record(stage: .asking)))
    }

    func testCompleteMarksTheClearWithoutUndoingALaterRound() {
        XCTAssertEqual(FreshStartPolicy.transition(.complete(epoch), from: committed(epoch)), .write(idle(cleared: epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.complete(epoch), from: agreeing(epoch)), .write(idle(cleared: epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.complete(epoch), from: idle(cleared: epoch)), .unchanged(idle(cleared: epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.complete(epoch), from: agreeing(later)),
                       .write(agreeing(later, cleared: epoch)))
        XCTAssertEqual(FreshStartPolicy.transition(.ask, from: committed(epoch, cleared: epoch)),
                       .write(Record(stage: .asking, clearedBefore: epoch)), "a finished commit doesn't block the next ask")
    }

    // MARK: Agreement

    func testCommittedNeedsACommitAndAnExactlyMatchingConsent() {
        XCTAssertNil(FreshStartPolicy.committedEpoch(mine: asking(epoch), theirs: agreeing(epoch)), "the asker hasn't committed")
        XCTAssertEqual(FreshStartPolicy.committedEpoch(mine: committed(epoch), theirs: agreeing(epoch)), epoch)
        XCTAssertEqual(FreshStartPolicy.committedEpoch(mine: agreeing(epoch), theirs: committed(epoch)), epoch)
        XCTAssertNil(FreshStartPolicy.committedEpoch(mine: agreeing(epoch), theirs: committed(later)),
                     "an agreement naming another ask does nothing")
        XCTAssertNil(FreshStartPolicy.committedEpoch(mine: agreeing(epoch), theirs: idle()), "withdrawn")
        // Either side finishing marks the commit it cleared.
        XCTAssertEqual(FreshStartPolicy.committedEpoch(mine: idle(cleared: epoch), theirs: agreeing(epoch)), epoch)
        XCTAssertEqual(FreshStartPolicy.committedEpoch(mine: agreeing(epoch), theirs: idle(cleared: epoch)), epoch)
        XCTAssertEqual(FreshStartPolicy.committedEpoch(mine: idle(cleared: epoch), theirs: asking(later, cleared: epoch)), epoch,
                       "a later ask keeps the earlier clear's mark")
    }

    // MARK: Phases and steps

    func testTheAskerCommitsOnSeeingTheAgreementThenClears() {
        var asker = state(mine: asking(epoch), theirs: nil)
        XCTAssertEqual(FreshStartPolicy.phase(asker, role: .owner), .asked(epoch))
        XCTAssertNil(FreshStartPolicy.nextStep(asker, role: .owner))

        asker.theirs = agreeing(epoch)
        XCTAssertEqual(FreshStartPolicy.phase(asker, role: .owner), .starting(epoch), "no withdraw once they've said yes")
        XCTAssertEqual(FreshStartPolicy.nextStep(asker, role: .owner), .publish(.commit(epoch)))

        asker.mine = committed(epoch)
        XCTAssertEqual(FreshStartPolicy.nextStep(asker, role: .owner), .clear(epoch))
        XCTAssertEqual(FreshStartPolicy.phase(asker, role: .owner), .clearing(epoch))
    }

    func testTheAgreerClearsOnlyAfterTheCommit() {
        var agreer = state(mine: nil, theirs: asking(epoch))
        XCTAssertEqual(FreshStartPolicy.phase(agreer, role: .participant), .theyAsked(epoch))
        XCTAssertNil(FreshStartPolicy.nextStep(agreer, role: .participant), "nothing happens without a yes")

        agreer.mine = agreeing(epoch)
        XCTAssertEqual(FreshStartPolicy.phase(agreer, role: .participant), .agreed(epoch))
        XCTAssertNil(FreshStartPolicy.nextStep(agreer, role: .participant), "waits for the asker's commit")

        agreer.theirs = committed(epoch)
        XCTAssertEqual(FreshStartPolicy.nextStep(agreer, role: .participant), .clear(epoch))
    }

    func testAQueuedWriteGoesFirstAndBlocksTheClear() {
        let pending = state(mine: committed(epoch), theirs: agreeing(epoch), pending: .commit(epoch))
        XCTAssertEqual(FreshStartPolicy.nextStep(pending, role: .owner), .publish(.commit(epoch)),
                       "the partner can't clear until our commit is on the server")
    }

    func testFinishedThenWaitingForThePartnerThenDone() {
        var done = state(mine: idle(cleared: epoch), theirs: agreeing(epoch), finished: epoch)
        XCTAssertNil(FreshStartPolicy.nextStep(done, role: .owner))
        XCTAssertEqual(FreshStartPolicy.phase(done, role: .owner), .waitingForPartner(epoch))
        done.theirs = idle(cleared: epoch)
        XCTAssertEqual(FreshStartPolicy.phase(done, role: .owner), .idle(lastCleared: epoch))
    }

    /// Both asked before seeing the other's: the later ask yields — consenting
    /// to clear before a time consents to clearing before any earlier one.
    func testBothAskingTheLaterAskConverts() {
        let earlier = state(mine: asking(epoch), theirs: asking(later))
        XCTAssertEqual(FreshStartPolicy.phase(earlier, role: .participant), .asked(epoch))
        XCTAssertNil(FreshStartPolicy.nextStep(earlier, role: .participant))

        let laterSide = state(mine: asking(later), theirs: asking(epoch))
        XCTAssertEqual(FreshStartPolicy.phase(laterSide, role: .owner), .agreed(epoch))
        XCTAssertEqual(FreshStartPolicy.nextStep(laterSide, role: .owner), .publish(.convert(epoch)))

        let tie = state(mine: asking(epoch), theirs: asking(epoch))
        XCTAssertNil(FreshStartPolicy.nextStep(tie, role: .owner), "a tie goes to the owner's ask")
        XCTAssertEqual(FreshStartPolicy.nextStep(tie, role: .participant), .publish(.convert(epoch)))
    }

    func testAnAskAlreadyClearedHereIsNotAskedAgain() {
        let stale = state(mine: idle(cleared: epoch), theirs: asking(epoch), finished: epoch)
        XCTAssertNotEqual(FreshStartPolicy.phase(stale, role: .owner), .theyAsked(epoch))
        let fresh = state(mine: idle(cleared: epoch), theirs: asking(later, cleared: epoch), finished: epoch)
        XCTAssertEqual(FreshStartPolicy.phase(fresh, role: .owner), .theyAsked(later), "a re-ask after a clear")
    }

    // MARK: The local state's own rules

    func testOurUnsentIntentOutranksTheServerCopy() {
        var held = state(mine: idle(), theirs: agreeing(epoch), pending: .withdraw)
        held.fold(FreshStart.Incoming(mine: asking(epoch)))
        XCTAssertEqual(held.mine, idle(), "a stale delta can't revive a withdrawn ask")

        held.published(.withdraw, .saved(idle()))
        XCTAssertNil(held.pendingIntent)
        held.fold(FreshStart.Incoming(mine: asking(later)))
        XCTAssertEqual(held.mine, asking(later), "published: another of our devices asked")
    }

    func testTheFilterMarkMovesOnlyOnAPublishedCommit() {
        var held = state(mine: asking(epoch), theirs: agreeing(epoch))
        XCTAssertTrue(held.begin(.commit(epoch)))
        held.fold(FreshStart.Incoming())
        XCTAssertNil(held.clearedBefore, "a commit the server could still refuse")

        held.published(.commit(epoch), .refused(idle()))
        XCTAssertNil(held.clearedBefore, "refused: our other device withdrew first")
        XCTAssertEqual(held.mine, idle())

        var agreed = state(mine: agreeing(epoch), theirs: nil)
        agreed.fold(FreshStart.Incoming(theirs: committed(epoch)))
        XCTAssertEqual(agreed.clearedBefore, epoch)
        agreed.fold(FreshStart.Incoming(theirsErased: true))
        XCTAssertEqual(agreed.clearedBefore, epoch, "never comes back down")
    }

    func testALateResultForAReplacedIntentIsIgnored() {
        var held = state(mine: nil, theirs: asking(epoch))
        held.begin(.agree(epoch))
        held.pendingIntent = .complete(epoch)
        held.published(.agree(epoch), .saved(agreeing(epoch)))
        XCTAssertEqual(held.pendingIntent, .complete(epoch))
    }

    func testCodableFallsBack() throws {
        let legacy = try decode(FreshStart.self, "{}")
        XCTAssertEqual(legacy, FreshStart())
        let future = try decode(FreshStart.self, """
            {"mine": {"stage": 9}, "pendingIntent": {"kind": "teleport"}, "clearedBefore": "2026-01-01T00:00:00Z"}
            """)
        XCTAssertEqual(future.mine?.stage, .idle, "a stage a newer build wrote")
        XCTAssertNil(future.pendingIntent, "an intent this build can't read is dropped")
        XCTAssertNotNil(future.clearedBefore)

        var full = state(mine: committed(epoch, cleared: Fixtures.t0), theirs: agreeing(epoch),
                         pending: .complete(epoch), finished: Fixtures.t0)
        full.clearedBefore = epoch
        full.dismissedAsk = later
        let data = try JSONEncoder.shared.encode(full)
        XCTAssertEqual(try JSONDecoder.shared.decode(FreshStart.self, from: data), full)
        for intent: FreshStartIntent in [.ask, .agree(epoch), .convert(epoch), .commit(epoch), .withdraw, .complete(epoch)] {
            XCTAssertEqual(try JSONDecoder.shared.decode(FreshStartIntent.self, from: JSONEncoder.shared.encode(intent)), intent)
        }
    }

    // MARK: The zone half

    private func item(_ name: String, _ created: Date?) -> FreshStartPolicy.ZoneItem {
        FreshStartPolicy.ZoneItem(recordName: name, createdAt: created)
    }

    func testTheZonePlanDeletesOnlyOurOwnHistoryFromBeforeTheEpoch() {
        let me = PairRole.owner
        let current = Fixtures.date(500)
        let items = [
            item(me.momentRecordName(id: "old"), Fixtures.date(999)),
            item(me.momentRecordName(id: "new"), epoch),
            item(me.momentRecordName(id: "undated"), nil),
            item(me.other.momentRecordName(id: "theirs"), Fixtures.date(10)),
            item(me.statusLogRecordName(at: Fixtures.date(100)), Fixtures.date(100)),
            item(me.statusLogRecordName(at: current), current),
            item(me.other.statusLogRecordName(at: Fixtures.date(200)), Fixtures.date(200)),
            item(me.receiptRecordName, later),
            item(me.statusRecordName, Fixtures.date(1)),
            item(me.nudgeRecordName, Fixtures.date(1)),
            item(me.freshStartRecordName, Fixtures.date(1)),
            item(CloudSync.anniversaryRecordName, Fixtures.date(1)),
        ]
        let plan = FreshStartPolicy.zonePlan(items, role: me, epoch: epoch, keepingStatusLogAt: current)

        XCTAssertEqual(Set(plan.deletions), [me.momentRecordName(id: "old"),
                                             me.statusLogRecordName(at: Fixtures.date(100)),
                                             me.receiptRecordName],
                       "never the partner's, never status/nudge (read as an unlink), never the mark itself")
        XCTAssertEqual(plan.zone.momentsBefore, ["old", "theirs"])
        XCTAssertEqual(plan.zone.momentsAfter, ["new", "undated"], "an undated record is kept, never guessed at")
        XCTAssertTrue(plan.zone.logsBefore.contains(.init(fromMe: false, at: Fixtures.date(200))))
        XCTAssertTrue(plan.zone.logsBefore.contains(.init(fromMe: true, at: current)),
                      "the current status's log is spared in the zone, not reclassified")
    }

    func testThePurgeTrustsTheZoneAndKeepsUnsentSends() {
        let zone = FreshStartPolicy.Zone(momentsBefore: ["cleared", "landedEarly"], momentsAfter: ["kept"],
                                         logsBefore: [.init(fromMe: false, at: Fixtures.date(1_500))],
                                         logsAfter: [.init(fromMe: true, at: Fixtures.date(5))])
        let moments = [
            Fixtures.moment("cleared", at: Fixtures.date(1_200)),
            Fixtures.moment("kept", at: Fixtures.date(5)),
            Fixtures.moment("landedEarly", at: Fixtures.date(10), fromMe: true, uploaded: false),
            Fixtures.moment("unsent", at: Fixtures.date(10), fromMe: true, uploaded: false),
            Fixtures.moment("goneOld", at: Fixtures.date(10)),
            Fixtures.moment("arrivedMeanwhile", at: later),
            Fixtures.moment("lostOwnOld", at: Fixtures.date(10), fromMe: true),
        ]
        let current = StatusHistoryEntry(emoji: "🌱", message: "now", isCelebration: false, at: Fixtures.date(1), fromMe: false)
        let log = [
            current,
            StatusHistoryEntry(emoji: "🥰", message: "", isCelebration: false, at: Fixtures.date(1_500), fromMe: false),
            StatusHistoryEntry(emoji: "☕️", message: "", isCelebration: false, at: Fixtures.date(5), fromMe: true),
            StatusHistoryEntry(emoji: "📼", message: "pre-cloud", isCelebration: false, at: Fixtures.date(2), fromMe: true),
            StatusHistoryEntry(emoji: "🌙", message: "", isCelebration: false, at: later, fromMe: true),
        ]
        let purge = FreshStartPolicy.purge(moments: moments, log: log, zone: zone, epoch: epoch,
                                           keeping: [.init(fromMe: false, at: current.at)])

        XCTAssertEqual(Set(purge.momentIDs), ["cleared", "landedEarly", "goneOld", "lostOwnOld"])
        XCTAssertFalse(purge.momentIDs.contains("unsent"), "the only copy: sent later, never dropped")
        XCTAssertFalse(purge.momentIDs.contains("kept"), "the zone's server time beats the sender's clock")
        XCTAssertEqual(purge.theirLogs, [Fixtures.date(1_500)], "the status still showing stays")
        XCTAssertEqual(purge.myLogs, [Fixtures.date(2)])
    }
}

/// Two phones and the zone, stepped by hand: each phone folds what the server
/// holds and runs its next step against the server copy, as the app does.
final class FreshStartHandshakeTests: XCTestCase {
    private struct Phone {
        let role: PairRole
        var state = FreshStart()
    }

    private var server: [PairRole: FreshStartRecord] = [:]
    private var clock = Fixtures.date(1_000)

    private func refresh(_ phone: inout Phone) {
        phone.state.fold(FreshStart.Incoming(mine: server[phone.role], mineErased: server[phone.role] == nil,
                                             theirs: server[phone.role.other], theirsErased: server[phone.role.other] == nil))
    }

    @discardableResult
    private func send(_ intent: FreshStartIntent, from phone: inout Phone) -> FreshStartPublishResult? {
        if intent == .ask {
            guard case .write(var record) = FreshStartPolicy.transition(.ask, from: server[phone.role]) else { return nil }
            clock = clock.addingTimeInterval(60)
            record.epoch = clock
            server[phone.role] = record
            phone.state.asked(.saved(record))
            return .saved(record)
        }
        guard phone.state.begin(intent) else { return nil }
        let result: FreshStartPublishResult
        switch FreshStartPolicy.transition(intent, from: server[phone.role]) {
        case .write(let record):
            server[phone.role] = record
            result = .saved(record)
        case .unchanged(let record): result = .saved(record)
        case .refused(let record): result = .refused(record)
        }
        phone.state.published(intent, result)
        return result
    }

    /// Runs the phone's steps; a clear "deletes" and finishes at once. Returns the epochs cleared.
    @discardableResult
    private func advance(_ phone: inout Phone) -> [Date] {
        var cleared: [Date] = []
        for _ in 0..<6 {
            guard let step = FreshStartPolicy.nextStep(phone.state, role: phone.role) else { break }
            switch step {
            case .publish(let intent):
                send(intent, from: &phone)
            case .clear(let epoch):
                // `CloudSync.clearHistory` re-checks the server copies first.
                XCTAssertTrue(FreshStartPolicy.isCommitted(epoch, mine: server[phone.role], theirs: server[phone.role.other]))
                cleared.append(epoch)
                phone.state.finished(epoch)
            }
        }
        return cleared
    }

    func testAskAgreeCommitClearOnBothPhones() {
        var owner = Phone(role: .owner)
        var partner = Phone(role: .participant)

        send(.ask, from: &owner)
        let epoch = clock
        refresh(&partner)
        XCTAssertEqual(FreshStartPolicy.phase(partner.state, role: .participant), .theyAsked(epoch))
        send(.agree(epoch), from: &partner)
        XCTAssertEqual(advance(&partner), [], "the agreer waits for the commit")

        refresh(&owner)
        XCTAssertEqual(advance(&owner), [epoch], "commit, clear, complete")
        XCTAssertEqual(server[.owner], FreshStartRecord(stage: .idle, clearedBefore: epoch))
        XCTAssertEqual(FreshStartPolicy.phase(owner.state, role: .owner), .waitingForPartner(epoch))

        refresh(&partner)
        XCTAssertEqual(advance(&partner), [epoch], "the asker's finished mark is commit enough")
        refresh(&owner)
        XCTAssertEqual(FreshStartPolicy.phase(owner.state, role: .owner), .idle(lastCleared: epoch))
        XCTAssertEqual(owner.state.clearedBefore, epoch)
        XCTAssertEqual(partner.state.clearedBefore, epoch)

        // A second device of the partner's with nothing local learns the mark from its own record.
        var secondDevice = Phone(role: .participant)
        refresh(&secondDevice)
        XCTAssertEqual(secondDevice.state.clearedBefore, epoch)
        XCTAssertEqual(advance(&secondDevice), [epoch], "its own copy is cleared too")
    }

    func testAWithdrawBeforeTheCommitStopsBothPhones() {
        var owner = Phone(role: .owner)
        var partner = Phone(role: .participant)
        send(.ask, from: &owner)
        let epoch = clock
        refresh(&partner)

        // The withdraw lands while the partner's yes is on its way.
        send(.withdraw, from: &owner)
        send(.agree(epoch), from: &partner)
        refresh(&owner)
        XCTAssertEqual(advance(&owner), [])
        refresh(&partner)
        XCTAssertEqual(advance(&partner), [])
        XCTAssertNil(owner.state.clearedBefore)
        XCTAssertEqual(FreshStartPolicy.phase(partner.state, role: .participant), .idle(lastCleared: nil),
                       "a stale agreement does nothing")

        // Asking again needs a new yes: the old agreement named the old epoch.
        send(.ask, from: &owner)
        refresh(&partner)
        XCTAssertEqual(FreshStartPolicy.phase(partner.state, role: .participant), .theyAsked(clock))
    }

    /// Two of the asker's devices: one withdraws while the other commits. The
    /// server takes one; the other is refused and adopts what's there.
    func testAWithdrawRacingTheCommitFromAnotherDevice() {
        var phoneA = Phone(role: .owner)
        var phoneB = Phone(role: .owner)
        var partner = Phone(role: .participant)
        send(.ask, from: &phoneA)
        let epoch = clock
        refresh(&phoneB)
        refresh(&partner)
        send(.agree(epoch), from: &partner)
        refresh(&phoneB)

        send(.withdraw, from: &phoneA)
        XCTAssertEqual(advance(&phoneB), [], "the commit is refused against the withdrawn record")
        XCTAssertEqual(phoneB.state.mine?.stage, .idle)
        refresh(&partner)
        XCTAssertEqual(advance(&partner), [])
    }

    func testBothAskingClearsOnceAtTheEarlierEpoch() {
        var owner = Phone(role: .owner)
        var partner = Phone(role: .participant)
        send(.ask, from: &owner)
        let first = clock
        send(.ask, from: &partner)

        refresh(&owner)
        XCTAssertEqual(advance(&owner), [], "the earlier asker waits")
        refresh(&partner)
        XCTAssertEqual(advance(&partner), [], "converts, then waits for the commit")
        XCTAssertEqual(server[.participant], FreshStartRecord(stage: .agreeing, epoch: first))

        refresh(&owner)
        XCTAssertEqual(advance(&owner), [first])
        refresh(&partner)
        XCTAssertEqual(advance(&partner), [first])
    }
}
