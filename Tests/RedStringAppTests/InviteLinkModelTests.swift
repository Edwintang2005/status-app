import XCTest

/// The owner's invite link (invariant 9): what the share check says, the
/// manual close, re-seat and reopen, and that changes never overlap or get
/// overwritten by an older look.
@MainActor
final class InviteLinkModelTests: XCTestCase {
    private let link = URL(string: "https://www.icloud.com/share/test")!

    private func partnerIn(_ stores: CloudStores, model: AppModel) {
        stores.shared.mutate { $0.theirs = Fixtures.status() }
        model.reload()
    }

    func testAPlainCloseWithNobodyInClosesTheLinkAndKeepsTheURL() async {
        let (model, backend, stores) = makeModel()
        await model.invite.refreshURL()
        await model.invite.close()
        XCTAssertEqual(backend.calls.filter { $0 == "closeUnusedInvite" }.count, 1)
        XCTAssertTrue(model.invite.isClosed)
        XCTAssertTrue(stores.shared.inviteClosed, "persisted")
        XCTAssertEqual(model.invite.url, link, "a closed link still re-admits the partner")
        XCTAssertFalse(model.invite.isChanging)
    }

    func testWithThePartnerInACloseOnlyAsksFirst() async {
        let (model, backend, stores) = makeModel()
        partnerIn(stores, model: model)
        await model.invite.close()
        XCTAssertTrue(model.invite.confirmingReseat, "the re-seat runs only once the owner confirms")
        XCTAssertFalse(backend.calls.contains("closeUnusedInvite"))
        XCTAssertFalse(model.invite.isClosed)
    }

    func testACloseThatFindsSomeoneOnTheShareAsksToReseat() async {
        let (model, backend, _) = makeModel()
        backend.inviteInUse = true
        await model.invite.close()
        XCTAssertTrue(model.invite.confirmingReseat)
        XCTAssertFalse(model.invite.isClosed)
    }

    func testOnlyOneChangeRunsAtATime() async {
        let (model, backend, _) = makeModel()
        let invite = model.invite
        backend.duringChange = { @MainActor [backend] in
            backend.duringChange = nil  // Once: without the guard this would recurse, not fail.
            XCTAssertTrue(invite.isChanging)
            await invite.close()
            await invite.reopen()
        }
        await invite.close()
        XCTAssertEqual(backend.calls.filter { $0 == "closeUnusedInvite" }.count, 1, "the nested close was refused")
        XCTAssertFalse(backend.calls.contains("reopenInvite"), "and so was the reopen")
    }

    func testALookTakenDuringAChangeIsDropped() async {
        let (model, backend, _) = makeModel()
        let invite = model.invite
        backend.share = ShareCheck(memberCount: 1, invite: .open(link))
        let midChange = Box<InviteState?>(nil)
        backend.duringChange = { @MainActor in midChange.value = await invite.checkMembers(throttled: false) }
        await invite.close()
        XCTAssertNil(midChange.value, "the server's answer predates the close")
        XCTAssertTrue(invite.isClosed, "the close stands")
    }

    func testALookThatACloseOvertookIsDropped() async {
        let (model, backend, _) = makeModel()
        let invite = model.invite
        backend.share = ShareCheck(memberCount: 1, invite: .open(link))
        // The look is out when a whole close runs and ends: only the counter can tell.
        backend.duringShareCheck = { @MainActor [backend] in
            backend.duringShareCheck = nil
            await invite.close()
            XCTAssertFalse(invite.isChanging)
        }
        let answer = await invite.checkMembers(throttled: false)
        XCTAssertNil(answer, "its \"open\" was read before the close")
        XCTAssertTrue(invite.isClosed, "and doesn't undo it")
    }

    func testASecondReseatWaitsForTheFirst() async {
        let (model, backend, stores) = makeModel()
        partnerIn(stores, model: model)
        let invite = model.invite
        backend.duringChange = { @MainActor [backend] in
            backend.duringChange = nil
            await invite.closeReseatingPartner()
        }
        await invite.closeReseatingPartner()
        XCTAssertEqual(backend.calls.filter { $0 == "lockIfPartnerOnShare" }.count, 1,
                       "a second confirmation mid-handshake would race the first's close and re-add")
    }

    func testTheReseatSaysWhatHappenedAndLooksAgain() async {
        let (model, backend, stores) = makeModel()
        partnerIn(stores, model: model)
        backend.share = ShareCheck(memberCount: 1, invite: .closed(link))
        await model.invite.closeReseatingPartner()
        XCTAssertEqual(backend.calls, ["lockIfPartnerOnShare", "shareCheck"], "re-read after the change ended")
        XCTAssertNotNil(model.invite.notice)
        XCTAssertTrue(model.invite.isClosed)

        backend.lockOutcome = .nobodyJoined
        await model.invite.closeReseatingPartner()
        XCTAssertTrue(backend.calls.contains("lockPairing"), "nobody accepted: the full lock")
    }

    func testAReopenSaysAnyoneWithTheLinkCanJoin() async {
        let (model, backend, stores) = makeModel()
        stores.shared.inviteClosed = true
        model.reload()
        backend.share = ShareCheck(memberCount: 1, invite: .open(link))
        await model.invite.reopen()
        XCTAssertTrue(backend.calls.contains("reopenInvite"))
        XCTAssertFalse(model.invite.isClosed, "the look after it read the link open")
        XCTAssertTrue(model.invite.notice?.contains("Anyone who has it can join") == true, model.invite.notice ?? "")
    }

    func testTheURLFollowsTheServer() async {
        let (model, backend, stores) = makeModel()
        backend.share = ShareCheck(memberCount: 1, invite: .closed(link))
        await model.invite.refreshURL()
        XCTAssertEqual(model.invite.url, link)
        XCTAssertTrue(model.invite.isClosed, "how this phone hears another closed it")
        XCTAssertEqual(stores.shared.inviteURL, link)

        backend.share = ShareCheck(memberCount: nil, invite: .missing)
        await model.invite.refreshURL()
        XCTAssertNil(model.invite.url)
        XCTAssertTrue(model.invite.isUnavailable, "no share: say so rather than spin")
        XCTAssertTrue(model.invite.isClosed, "nothing says the partner joined: closed isn't claimed or undone")
    }

    func testHomePromptsToCloseOnlyOnceTheServerSaysOpenWithThePartnerIn() async {
        let (model, backend, stores) = makeModel()
        XCTAssertFalse(model.invite.showsClosePrompt, "nothing checked yet")
        partnerIn(stores, model: model)
        await model.invite.checkMembers(throttled: false)
        XCTAssertTrue(model.invite.showsClosePrompt)

        backend.share = ShareCheck(memberCount: 2, invite: .open(link))
        await model.invite.checkMembers(throttled: false)
        XCTAssertEqual(model.invite.extraMembers, 2, "a stranger on the share")
        XCTAssertFalse(model.invite.showsClosePrompt, "the stranger warning comes first")

        backend.share = ShareCheck(memberCount: 1, invite: .open(link))
        await model.invite.checkMembers(throttled: false)
        model.invite.dismissClosePrompt()
        XCTAssertFalse(model.invite.showsClosePrompt)
        XCTAssertTrue(stores.shared.closeLinkPromptDismissed)
    }

    func testAThrottledLookWaitsItsInterval() async {
        let (model, backend, _) = makeModel()
        await model.invite.checkMembers(throttled: true, now: Fixtures.t0)
        await model.invite.checkMembers(throttled: true, now: Fixtures.t0.addingTimeInterval(1))
        XCTAssertEqual(backend.calls.filter { $0 == "shareCheck" }.count, 1)
        await model.invite.checkMembers(throttled: true,
                                        now: Fixtures.t0.addingTimeInterval(AppConfig.shareMemberCheckInterval))
        XCTAssertEqual(backend.calls.filter { $0 == "shareCheck" }.count, 2)
    }

    func testAClosedLinkTrustsAnEarlierLaunchsLookForADay() async {
        let stores = makeStores()
        stores.shared.inviteClosed = true
        stores.shared.shareCheckedAt = Fixtures.t0
        let backend = FakeAppBackend()
        let model = AppModel(stores: stores, backend: backend, environment: .detached)
        await model.invite.checkMembers(throttled: true, now: Fixtures.t0.addingTimeInterval(60))
        XCTAssertTrue(backend.calls.isEmpty, "closed, nobody new can join")
        await model.invite.checkMembers(throttled: true,
                                        now: Fixtures.t0.addingTimeInterval(AppConfig.closedShareCheckInterval))
        XCTAssertEqual(backend.calls, ["shareCheck"])
    }

    func testAParticipantNeverLooks() async {
        let (model, backend, _) = makeModel(paired: .participant)
        await model.invite.refreshURL()
        await model.invite.checkMembers(throttled: false)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testUnlinkingForgetsWhatTheLastLookSaid() async {
        let (model, backend, stores) = makeModel()
        backend.share = ShareCheck(memberCount: 3, invite: .open(link))
        await model.invite.checkMembers(throttled: false)
        XCTAssertTrue(model.invite.postureChecked)
        stores.shared.pairing = nil
        model.reload()
        XCTAssertNil(model.invite.memberCount)
        XCTAssertFalse(model.invite.postureChecked)
    }
}
