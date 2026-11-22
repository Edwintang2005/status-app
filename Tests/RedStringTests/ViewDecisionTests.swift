import XCTest

/// The decisions screens used to make inline (redesign 4): what "save memories"
/// allows before a delete, Home's notice and footer, the status draft, the
/// gallery's paging and where a tapped picture opens.
final class ViewDecisionTests: XCTestCase {
    // MARK: Ending plan — what stands between an archive and a delete

    func testAnIncompleteArchiveNeverEndsAnything() {
        for gate in [ArchiveGate.retry, .updateFirst] {
            for deviceOnly in [false, true] {
                let plan = EndingPlan(gate: gate, deviceOnly: deviceOnly, ending: true)
                XCTAssertEqual(plan.step, .refuse, "\(gate), deviceOnly \(deviceOnly)")
                XCTAssertEqual(plan.sharesFirst, deviceOnly, "a device-only archive is still offered for sharing")
            }
        }
    }

    func testMomentsWithNoFileAreAlwaysAskedAbout() {
        let drive = EndingPlan(gate: .confirmGone(3), deviceOnly: false, ending: true)
        XCTAssertEqual(drive.step, .confirm)
        XCTAssertFalse(drive.sharesFirst)
        XCTAssertTrue(drive.check.contains("3"), drive.check)
        XCTAssertFalse(drive.check.contains("only shared from this iPhone"), drive.check)

        let device = EndingPlan(gate: .confirmGone(1), deviceOnly: true, ending: true)
        XCTAssertEqual(device.step, .confirm)
        XCTAssertTrue(device.sharesFirst, "shared before it's asked about")
        XCTAssertTrue(device.check.contains("1 moment is no longer in iCloud"), device.check)
        XCTAssertTrue(device.check.contains("only shared from this iPhone"), "both reasons, in one ask")
    }

    func testADeviceOnlyArchiveIsSharedThenConfirmed() {
        let plan = EndingPlan(gate: .proceed, deviceOnly: true, ending: true)
        XCTAssertEqual(plan.step, .confirm, "never straight to the delete")
        XCTAssertTrue(plan.sharesFirst)
        XCTAssertFalse(plan.check.isEmpty, "says the archive is only on this iPhone")
    }

    func testOnlyACompleteArchiveInICloudDriveEndsAtOnce() {
        let plan = EndingPlan(gate: .proceed, deviceOnly: false, ending: true)
        XCTAssertEqual(plan.step, .end)
        XCTAssertFalse(plan.sharesFirst)
        XCTAssertEqual(plan.check, "")
        // Every other combination stops short of ending at once.
        for gate in [ArchiveGate.proceed, .retry, .updateFirst, .confirmGone(1)] {
            for deviceOnly in [false, true] where gate != .proceed || deviceOnly {
                XCTAssertNotEqual(EndingPlan(gate: gate, deviceOnly: deviceOnly, ending: true).step, .end,
                                  "\(gate), deviceOnly \(deviceOnly)")
            }
        }
    }

    func testAnArchiveAloneOnlyReports() {
        for gate in [ArchiveGate.proceed, .retry, .updateFirst, .confirmGone(2)] {
            XCTAssertEqual(EndingPlan(gate: gate, deviceOnly: false, ending: false).step, .report, "\(gate)")
            XCTAssertEqual(EndingPlan(gate: gate, deviceOnly: true, ending: false).step, .none,
                           "the share sheet is the report")
        }
    }

    func testTheSummarySaysWhatWasLeftOut() {
        let outcome = ArchiveOutcome(folder: URL(fileURLWithPath: "/tmp/Memories 2026"), destination: .iCloudDrive,
                                     momentCount: 1, statusCount: 4, unrecovered: 2, unsupported: 0, gone: 1,
                                     gate: .retry, includesZone: false, unreadable: 5)
        let text = outcome.summary
        XCTAssertTrue(text.contains("1 moment and 4 statuses"), text)
        XCTAssertTrue(text.contains("Memories 2026"), text)
        XCTAssertTrue(text.contains("2 couldn't be fetched"), text)
        XCTAssertTrue(text.contains("1 are no longer in iCloud"), text)
        XCTAssertTrue(text.contains("iCloud couldn't be reached"), text)
        XCTAssertFalse(text.contains("couldn't be read"), "no zone read: nothing to call unreadable")
        XCTAssertFalse(text.contains("newer version"))
    }

    // MARK: Home's notice

    func testHomeShowsTheMostUrgentNotice() {
        var all = HomeNotice.Inputs(partnerLeft: true, extraMembers: 1, iCloudProblem: "signed out",
                                    clearingHistory: true, freshStartStuck: true, freshStartRequest: true,
                                    notificationsProblem: .off, closeLink: true, widgetTip: true,
                                    recap: .year(2026))
        let order: [HomeNotice] = [.partnerLeft, .extraMembers(1), .iCloud("signed out"), .freshStartClearing,
                                   .freshStartStuck, .freshStartRequest, .notificationsOff(.off), .closeLink,
                                   .widgetTip, .recap(.year(2026))]
        for expected in order {
            XCTAssertEqual(HomeNotice.pick(from: all), expected)
            switch expected {
            case .partnerLeft: all.partnerLeft = false
            case .extraMembers: all.extraMembers = nil
            case .iCloud: all.iCloudProblem = nil
            case .freshStartClearing: all.clearingHistory = false
            case .freshStartStuck: all.freshStartStuck = false
            case .freshStartRequest: all.freshStartRequest = false
            case .notificationsOff: all.notificationsProblem = nil
            case .closeLink: all.closeLink = false
            case .widgetTip: all.widgetTip = false
            case .recap: all.recap = nil
            }
        }
        XCTAssertNil(HomeNotice.pick(from: all))
    }

    func testOfflineHidesTheICloudProblem() {
        let offline = HomeNotice.Inputs(iCloudProblem: "network", offline: true, widgetTip: true)
        XCTAssertEqual(HomeNotice.pick(from: offline), .widgetTip, "the offline card covers it")
    }

    // MARK: Sync footer

    func testTheFooterShowsTheMostPressingLine() {
        let synced = Fixtures.t0
        var inputs = SyncFooterLine.Inputs(partnerName: "Sam", showsSent: true, isOffline: true, lastSyncedAt: synced,
                                           isRefreshing: true, needsICloudAttention: true, isSending: true,
                                           pendingCount: 2, syncFailing: true)
        XCTAssertEqual(SyncFooterLine(inputs), .sent)
        inputs.showsSent = false
        XCTAssertEqual(SyncFooterLine(inputs), .offline(lastSyncedAt: synced))
        inputs.isOffline = false
        XCTAssertEqual(SyncFooterLine(inputs), .syncing(restoring: false))
        inputs.isRefreshing = false
        XCTAssertEqual(SyncFooterLine(inputs), .iCloudAttention)
        inputs.needsICloudAttention = false
        XCTAssertEqual(SyncFooterLine(inputs), .sending)
        inputs.isSending = false
        XCTAssertEqual(SyncFooterLine(inputs), .waiting(label: "2 waiting to send · tap to retry", storageFull: false),
                       "ahead of a failing sync: a send is still on this phone")
        inputs.pendingCount = 0
        XCTAssertEqual(SyncFooterLine(inputs), .failing(lastSyncedAt: synced))
        inputs.syncFailing = false
        XCTAssertEqual(SyncFooterLine(inputs), .synced(synced))
        inputs.lastSyncedAt = nil
        XCTAssertEqual(SyncFooterLine(inputs), .neverSynced)
    }

    func testOnlyARetryLineIsAButton() {
        XCTAssertTrue(SyncFooterLine(.init(pendingCount: 1)).isButton)
        XCTAssertTrue(SyncFooterLine(.init(syncFailing: true)).isButton)
        XCTAssertFalse(SyncFooterLine(.init(isRefreshing: true, pendingCount: 1)).isButton)
        XCTAssertFalse(SyncFooterLine(.init(lastSyncedAt: Fixtures.t0)).isButton)
    }

    func testAFullICloudSaysWhoseItIs() {
        func label(_ inputs: SyncFooterLine.Inputs) -> String? {
            if case .waiting(let label, _) = SyncFooterLine(inputs) { label } else { nil }
        }
        XCTAssertEqual(label(.init(pendingCount: 1, onlyStatusPending: true)),
                       "Your status is waiting to send · tap to retry")
        XCTAssertEqual(label(.init(pendingCount: 1)), "1 waiting to send · tap to retry")
        XCTAssertEqual(label(.init(partnerName: "Sam", pendingCount: 1, onlyStatusPending: true,
                                   storageFull: true, isParticipant: true)),
                       "Sam's iCloud is full · 1 waiting · tap to retry", "only the owner can make room")
        XCTAssertEqual(label(.init(pendingCount: 3, storageFull: true)), "Your iCloud is full · 3 waiting · tap to retry")
    }

    // MARK: Status draft

    private let presets: Set<String> = ["Sleeping", "At work"]
    private func isPreset(_ text: String) -> Bool { presets.contains(text) }

    func testAPresetFillsTheWordsOnlyWhenNoneWereTyped() {
        var draft = StatusDraft()
        XCTAssertFalse(draft.pick(Mood(emoji: "😴", label: "Sleeping"), isPresetLabel: isPreset))
        XCTAssertEqual(draft.message, "Sleeping")
        draft.pick(Mood(emoji: "💼", label: "At work"), isPresetLabel: isPreset)
        XCTAssertEqual(draft.message, "At work", "a preset's label is swapped")

        draft.message = "home by 6"
        draft.pick(Mood(emoji: "😴", label: "Sleeping"), isPresetLabel: isPreset)
        XCTAssertEqual(draft.message, "home by 6", "hand-typed words survive: the tap picks the emoji")
        XCTAssertEqual(draft.emoji, "😴")
        XCTAssertEqual(draft.selectedPresetID, "😴-Sleeping")
    }

    func testASurpriseClearsAPresetsWordsAndAsksForTheNews() {
        var draft = StatusDraft()
        draft.pick(Mood(emoji: "😴", label: "Sleeping"), isPresetLabel: isPreset)
        let surprise = Mood(emoji: "🎁", label: "Guess what", celebration: .reveal)
        XCTAssertTrue(draft.pick(surprise, isPresetLabel: isPreset), "the words field takes focus")
        XCTAssertEqual(draft.message, "", "a sealed \"guess what\" would reveal nothing")
        XCTAssertFalse(draft.hasChange(from: ""), "a surprise needs its news")
        draft.message = "we got the flat"
        XCTAssertTrue(draft.hasChange(from: ""))
        XCTAssertEqual(draft.celebration, .reveal)
    }

    func testSetWaitsForAChange() {
        var draft = StatusDraft(emoji: "🥰")
        XCTAssertFalse(draft.hasChange(from: "🥰"), "the carried-over emoji alone re-posts nothing")
        draft.emoji = "🌙"
        XCTAssertTrue(draft.hasChange(from: "🥰"))
        draft = StatusDraft(emoji: "🥰", message: "   ")
        XCTAssertFalse(draft.hasChange(from: "🥰"), "spaces aren't words")
        draft.selectedPresetID = "🥰-Missing you"
        XCTAssertTrue(draft.hasChange(from: "🥰"), "the current status, re-posted on purpose")
    }

    func testTypedWordsGuardTheSheetAndGoWithASpeechBubble() {
        var draft = StatusDraft()
        XCTAssertFalse(draft.guardsDismissal)
        draft.message = "on my way"
        XCTAssertTrue(draft.guardsDismissal, "a stray swipe doesn't lose them")
        XCTAssertTrue(draft.needsEmojiHint)
        XCTAssertEqual(draft.sentEmoji, "💬")
        draft.emoji = "🚗"
        XCTAssertFalse(draft.needsEmojiHint)
        XCTAssertEqual(draft.sentEmoji, "🚗")
    }

    func testATypedEmojiDropsTheTileAndItsCelebration() {
        var draft = StatusDraft()
        draft.pick(Mood(emoji: "🎉", label: "Party", celebration: .confetti), isPresetLabel: isPreset)
        draft.typedEmoji()
        XCTAssertNil(draft.selectedPresetID)
        XCTAssertNil(draft.celebration)
        XCTAssertEqual(draft.message, "Party", "the words stay")
    }

    func testARecentStatusIsTakenWhole() {
        var draft = StatusDraft(celebration: .confetti)
        let entry = StatusHistoryEntry(emoji: "☕️", message: "coffee?", isCelebration: true, at: Fixtures.t0, fromMe: true)
        draft.pick(recent: entry)
        XCTAssertEqual(draft.emoji, "☕️")
        XCTAssertEqual(draft.message, "coffee?")
        XCTAssertEqual(draft.selectedPresetID, entry.id)
        XCTAssertNil(draft.celebration, "a recent status never re-arms a celebration")
    }

    func testTheWordsAreCapped() {
        var draft = StatusDraft(message: String(repeating: "a", count: AppConfig.statusMessageMaxLength + 5))
        draft.capMessage()
        XCTAssertEqual(draft.message.count, AppConfig.statusMessageMaxLength)
    }

    // MARK: Gallery paging

    func testARemovedPageMovesOnThenBack() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(GalleryPaging.settle("b", order: order, remaining: ["a", "b", "c", "d"]), "b", "still there")
        XCTAssertEqual(GalleryPaging.settle("b", order: order, remaining: ["a", "c", "d"]), "c", "the next")
        XCTAssertEqual(GalleryPaging.settle("b", order: order, remaining: ["a", "d"]), "d", "the next still there")
        XCTAssertEqual(GalleryPaging.settle("d", order: order, remaining: ["a", "b"]), "b", "the last: the one before")
        XCTAssertNil(GalleryPaging.settle("b", order: order, remaining: []), "none left: close")
    }

    // MARK: Tapped picture

    func testATappedPictureOpensAmongTheUnseenOrAlone() {
        let a = Fixtures.moment("a"), b = Fixtures.moment("b"), seen = Fixtures.moment("s", seen: true)
        let among = CarouselPlan.opening(b, unseen: [a, b], arrivals: [a, b])
        XCTAssertEqual(among.start?.id, "b")
        XCTAssertEqual(among.queue.map(\.id), ["a", "b"], "pages through every unseen one")
        let alone = CarouselPlan.opening(seen, unseen: [a, b], arrivals: [a, b])
        XCTAssertEqual(alone.queue.map(\.id), ["s"])
        let missing = CarouselPlan.opening(nil, unseen: [a], arrivals: [a, b])
        XCTAssertNil(missing.start)
        XCTAssertEqual(missing.queue.map(\.id), ["a", "b"], "not filed: the new arrivals stand in")
    }

    // MARK: Moment motion

    func testOnlyAPartnersUnseenPictureDevelopsAndOnlyOnce() {
        let fresh = Fixtures.moment("p1", seen: false)
        XCTAssertTrue(MomentMotion.develops(fresh, developed: []))
        XCTAssertFalse(MomentMotion.develops(fresh, developed: ["p1"]), "once per gallery")
        XCTAssertFalse(MomentMotion.develops(Fixtures.moment("p2", seen: true), developed: []), "already looked at")
        XCTAssertFalse(MomentMotion.develops(Fixtures.moment("o1", fromMe: true, seen: false), developed: []),
                       "your own was never unseen to you")
        XCTAssertFalse(MomentMotion.develops(Fixtures.moment("v1", kind: .voice, seen: false), developed: []),
                       "a memo has no picture")
        XCTAssertTrue(MomentMotion.develops(Fixtures.moment("d1", kind: .drawing, seen: false), developed: []))
    }
}
