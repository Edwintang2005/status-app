import XCTest

/// The App Group key/value store against a throwaway defaults suite: defaults,
/// the locked read-modify-write, derived fields, and the corrupt-snapshot sidecar.
final class SharedStoreTests: XCTestCase {
    private func makeStore() -> (SharedStore, UserDefaults) {
        let defaults = temporaryDefaults()
        return (SharedStore(defaults: defaults), defaults)
    }

    func testFreshStoreDefaults() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.snapshot, .empty)
        XCTAssertNil(store.pairing)
        XCTAssertTrue(store.readReceiptsEnabled, "on by default")
        XCTAssertFalse(store.inviteClosed)
        XCTAssertNil(store.inviteURL)
        XCTAssertNil(store.changeToken(for: "private"))
        XCTAssertEqual(store.unreadableTally.summary, "none")
    }

    // MARK: Owed records (CLAUDE.md invariant 2)

    /// Missed records are owed once each, by the time first missed; read or
    /// deleted, they're settled; every miss still counts for Diagnostics.
    func testMissedRecordsAreOwedUntilReadOrDeleted() {
        let (store, _) = makeStore()
        let t0 = Fixtures.t0
        store.noteFetched(missed: ["a"], settled: [], now: t0)
        store.noteFetched(missed: ["a", "b"], settled: [], now: t0.addingTimeInterval(60),
                          process: "notification service")
        var tally = store.unreadableTally
        XCTAssertEqual(tally.heldNames, ["a", "b"])
        XCTAssertEqual(tally.heldSince, t0.addingTimeInterval(60), "the latest miss: a fresh one isn't hidden by an old one")
        XCTAssertEqual(tally.counts, ["app": 1, "notification service": 2])

        store.noteFetched(missed: [], settled: ["a"], now: t0.addingTimeInterval(120))
        tally = store.unreadableTally
        XCTAssertEqual(tally.heldNames, ["b"])
        store.noteFetched(missed: [], settled: ["b"], now: t0.addingTimeInterval(180))
        XCTAssertNil(store.unreadableTally.heldSince)
        XCTAssertEqual(store.unreadableTally.counts["app"], 1, "settling keeps the evidence")
    }

    /// A record nobody can ever read isn't owed forever, and a zone can't grow the list without end.
    func testOwedRecordsAgeOutAndStayBounded() {
        var tally = SharedStore.UnreadableTally()
        tally.update(missed: ["old"], settled: [], now: Fixtures.t0)
        tally.update(missed: ["new"], settled: [], now: Fixtures.t0.addingTimeInterval(AppConfig.owedRecordLifetime + 1))
        XCTAssertEqual(tally.heldNames, ["new"])
        XCTAssertEqual(tally.abandoned, 1)

        tally.update(missed: (0..<(AppConfig.owedRecordLimit + 3)).map { "r\($0)" }, settled: [],
                     now: Fixtures.t0.addingTimeInterval(AppConfig.owedRecordLifetime + 2))
        XCTAssertEqual(tally.owed.count, AppConfig.owedRecordLimit)
        XCTAssertEqual(tally.heldNames.last, "r\(AppConfig.owedRecordLimit + 2)", "the newest kept")
    }

    /// One fetch by ID at a time across processes, newest first, an extension's share capped.
    func testARetryIsClaimedOncePerSpacingAcrossProcesses() {
        let (store, _) = makeStore()
        XCTAssertNil(store.claimOwedRetry(now: Fixtures.t0), "nothing owed")
        store.noteFetched(missed: ["a", "b", "c"], settled: [], now: Fixtures.t0)
        XCTAssertEqual(store.claimOwedRetry(now: Fixtures.t0, limit: 2)?.map(\.name), ["c", "b"])
        XCTAssertNil(store.claimOwedRetry(now: Fixtures.t0.addingTimeInterval(30)), "within the spacing")
        XCTAssertNotNil(store.claimOwedRetry(now: Fixtures.t0.addingTimeInterval(AppConfig.owedRetrySpacing + 1)))
    }

    /// After a retry that read nothing, an extension waits longer; the app doesn't.
    func testAnExtensionBacksOffAfterABlindRetry() {
        let (store, _) = makeStore()
        store.noteFetched(missed: ["a"], settled: [], now: Fixtures.t0)
        XCTAssertNotNil(store.claimOwedRetry(now: Fixtures.t0, isExtension: true))
        store.noteOwedRetry(fetched: true, readAny: false)
        let later = Fixtures.t0.addingTimeInterval(AppConfig.owedRetrySpacing + 1)
        XCTAssertNil(store.claimOwedRetry(now: later, isExtension: true))
        XCTAssertNotNil(store.claimOwedRetry(now: later, isExtension: false), "the app with its keys tries")
    }

    func testLegacyTallyDecodes() throws {
        let tally = try decode(SharedStore.UnreadableTally.self,
                               #"{"counts":{"widget":3},"heldNames":["x"],"heldStreak":2}"#)
        XCTAssertEqual(tally.counts["widget"], 3)
        XCTAssertTrue(tally.owed.isEmpty, "the old hold's records come back with the delta it pinned")
        XCTAssertEqual(tally.abandoned, 0)
        XCTAssertNil(tally.heldSince)
    }

    /// Diagnostics' "Last notification": written by the notification service, read by the app.
    func testTheLastBannerPassRoundTrips() {
        let (store, _) = makeStore()
        XCTAssertNil(store.lastBannerPass)
        let pass = SharedStore.BannerPass(at: Fixtures.date(0), outcome: .timedOut, seconds: 29.6, detail: nil)
        store.lastBannerPass = pass
        XCTAssertEqual(store.lastBannerPass, pass)
        XCTAssertTrue(pass.summary.contains("29.6"))
        store.lastBannerPass = SharedStore.BannerPass(at: Fixtures.date(0), outcome: .failed, seconds: 3,
                                                      detail: "The Internet connection appears to be offline.")
        XCTAssertTrue(store.lastBannerPass?.summary.contains("offline") == true)
    }

    func testReadReceiptsToggleRoundTrips() {
        let (store, _) = makeStore()
        store.readReceiptsEnabled = false
        XCTAssertFalse(store.readReceiptsEnabled)
        store.readReceiptsEnabled = true
        XCTAssertTrue(store.readReceiptsEnabled)
    }

    func testMutatePersistsAndReturnsTheResult() {
        let (store, _) = makeStore()
        let result = store.mutate(reloadWidgets: false) {
            $0.isPaired = true
            $0.lastSeenPartnerNudgeCount = max($0.lastSeenPartnerNudgeCount, 4)
        }
        XCTAssertTrue(result.isPaired)
        XCTAssertEqual(store.snapshot.lastSeenPartnerNudgeCount, 4)
    }

    func testPairingAndTokensRoundTrip() {
        let (store, _) = makeStore()
        let info = PairingInfo(role: .owner, zoneName: "CoupleZone", zoneOwnerName: "_me",
                               pairedAt: Fixtures.t0, userRecordName: "_me")
        store.pairing = info
        XCTAssertEqual(store.pairing, info)
        store.setChangeToken(Data([1, 2, 3]), for: "private")
        XCTAssertEqual(store.changeToken(for: "private"), Data([1, 2, 3]))
        store.pairing = nil
        XCTAssertNil(store.pairing)
    }

    func testUnlinkRemembersTheZoneAndStartOverForgetsIt() {
        let (store, _) = makeStore()
        let info = PairingInfo(role: .participant, zoneName: "CoupleZone", zoneOwnerName: "_owner",
                               pairedAt: Fixtures.t0)
        store.pairing = info
        store.clearPairing(keepingName: true)
        XCTAssertEqual(store.lastPairing?.sameZone(as: info), true)
        store.pairing = info
        store.clearPairing(keepingName: false)
        XCTAssertNil(store.lastPairing)
    }

    /// The cached own records name the old zone: a new pairing must fetch its own.
    func testRecordCachesClearWithThePairing() {
        let (store, _) = makeStore()
        store.nudgeRecordCache = .init(systemFields: Data([1]), count: 3)
        store.statusRecordCache = .init(systemFields: Data([2]), payload: Fixtures.status(at: Fixtures.t0))
        XCTAssertEqual(store.statusRecordCache?.systemFields, Data([2]))
        store.clearPairing(keepingName: true)
        XCTAssertNil(store.nudgeRecordCache)
        XCTAssertNil(store.statusRecordCache)
    }

    func testZoneGoneSightingClearsWithThePairing() {
        let (store, _) = makeStore()
        XCTAssertNil(store.zoneGoneSeenAt)
        store.zoneGoneSeenAt = Fixtures.t0
        XCTAssertEqual(store.zoneGoneSeenAt, Fixtures.t0)
        store.clearPairing(keepingName: false)
        XCTAssertNil(store.zoneGoneSeenAt, "a new pairing starts with no stale sighting")
    }

    /// The close-link card is per pairing (a new link is open again); the widget tip is per device.
    func testHomeCardDismissalsScope() {
        let (store, _) = makeStore()
        store.closeLinkPromptDismissed = true
        store.widgetTipDismissed = true
        store.clearPairing(keepingName: true)
        XCTAssertFalse(store.closeLinkPromptDismissed)
        XCTAssertTrue(store.widgetTipDismissed)
    }

    func testInviteURLRoundTrips() {
        let (store, _) = makeStore()
        let url = URL(string: "https://www.icloud.com/share/abc#RedString")!
        store.inviteURL = url
        XCTAssertEqual(store.inviteURL, url)
        store.inviteURL = nil
        XCTAssertNil(store.inviteURL)
    }

    func testCorruptSnapshotIsPreservedInASidecarKey() {
        let (store, defaults) = makeStore()
        let garbage = Data("not a snapshot".utf8)
        defaults.set(garbage, forKey: "snapshot")
        XCTAssertEqual(store.snapshot, .empty)
        XCTAssertEqual(defaults.data(forKey: "snapshot.corrupt"), garbage)
    }

    func testDerivedFieldsFollowTheIndex() {
        let (store, _) = makeStore()
        var heard = Fixtures.moment("v0", kind: .voice, at: Fixtures.date(-300))
        heard.seen = true
        let all = [
            Fixtures.moment("o1", at: Fixtures.t0, fromMe: true),
            Fixtures.moment("v1", kind: .voice, at: Fixtures.date(-10)),
            Fixtures.moment("p1", at: Fixtures.date(-20)),
            heard,
        ]
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert(all)
        XCTAssertTrue(store.refreshDerived(reloadWidgets: false, index: index).changed)
        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.latestOwnMoment?.id, "o1")
        XCTAssertEqual(snapshot.latestPartnerMoment?.id, "v1")
        XCTAssertEqual(snapshot.latestPartnerVisualMoment?.id, "p1", "a memo never displaces the picture")
        XCTAssertEqual(snapshot.unheardVoiceMemoCount, 1)

        index.markSeen(ids: ["p1"])
        XCTAssertFalse(store.refreshDerived(reloadWidgets: false, index: index).changed,
                       "a photo marked seen changes nothing a widget draws")

        index.clear()
        store.refreshDerived(reloadWidgets: false, index: index)
        XCTAssertNil(store.snapshot.latestPartnerVisualMoment, "must return to nil when the last picture goes")
        XCTAssertEqual(store.snapshot.unheardVoiceMemoCount, 0)
    }

    /// The user's example: hide moment 2, the widget shows 1; moment 3 arrives,
    /// shows, and the hide is gone. Nothing leaves this phone.
    func testAHiddenPictureLeavesTheWidgetUntilANewerOneArrives() {
        let (store, _) = makeStore()
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert([Fixtures.moment("m1", at: Fixtures.date(-20)), Fixtures.moment("m2", at: Fixtures.date(-10))])
        store.refreshDerived(reloadWidgets: false, index: index)
        XCTAssertEqual(store.snapshot.latestPartnerVisualMoment?.id, "m2")

        let hidden = store.refreshDerived(reloadWidgets: false, index: index) { $0.widgetHiddenMomentIDs.append("m2") }
        XCTAssertTrue(hidden.changed, "the widget redraws")
        XCTAssertEqual(store.snapshot.latestPartnerVisualMoment?.id, "m1")
        XCTAssertEqual(store.snapshot.widgetHiddenMomentIDs, ["m2"])

        index.insert([Fixtures.moment("v3", kind: .voice, at: Fixtures.date(-5)),
                      Fixtures.moment("o3", at: Fixtures.date(-4), fromMe: true)])
        store.refreshDerived(reloadWidgets: false, index: index)
        XCTAssertEqual(store.snapshot.latestPartnerVisualMoment?.id, "m1", "a memo or an own send isn't a new picture")

        index.insert([Fixtures.moment("m3")])
        store.refreshDerived(reloadWidgets: false, index: index)
        XCTAssertEqual(store.snapshot.latestPartnerVisualMoment?.id, "m3")
        XCTAssertEqual(store.snapshot.widgetHiddenMomentIDs, [], "the hide ends with the new picture")

        index.clear()
        index.insert([Fixtures.moment("m1", at: Fixtures.date(-20)), Fixtures.moment("m2", at: Fixtures.date(-10))])
        store.refreshDerived(reloadWidgets: false, index: index)
        XCTAssertEqual(store.snapshot.latestPartnerVisualMoment?.id, "m2", "so m3 going doesn't bring the hide back")
    }

    func testTheWidgetPictureSkipsOnlyTheHiddenRunAboveIt() {
        let pictures = ["a", "b", "c", "d"].map { Fixtures.moment($0) }
        let both = WidgetPicture.choose(pictures, hidden: ["b", "a"])
        XCTAssertEqual(both.shown?.id, "c")
        XCTAssertEqual(Set(both.stillHidden), ["a", "b"])
        let below = WidgetPicture.choose(pictures, hidden: ["c"])
        XCTAssertEqual(below.shown?.id, "a", "a mark under the shown picture is stale")
        XCTAssertEqual(below.stillHidden, [])
        let all = WidgetPicture.choose(pictures, hidden: ["a", "b", "c", "d"])
        XCTAssertNil(all.shown, "every picture hidden: the widget's empty state")
        XCTAssertEqual(all.stillHidden.count, 4)
        XCTAssertEqual(WidgetPicture.choose(pictures, hidden: ["gone"]).stillHidden, [], "a deleted moment's mark goes")
    }

    /// `markSeen`'s path: the receipt flag lands in the same write as the
    /// derived fields, and the returned snapshot is what was stored.
    func testRefreshDerivedAppliesTheCallersChangeInTheSameWrite() {
        let (store, _) = makeStore()
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert([Fixtures.moment("v1", kind: .voice)])
        let refreshed = store.refreshDerived(reloadWidgets: false, index: index) { $0.receiptsDirty = true }
        XCTAssertTrue(refreshed.changed)
        XCTAssertTrue(refreshed.snapshot.receiptsDirty)
        XCTAssertEqual(refreshed.snapshot.unheardVoiceMemoCount, 1)
        XCTAssertEqual(store.snapshot, refreshed.snapshot)
    }

    /// The caller's change lands even when the index can't be read.
    func testRefreshDerivedAppliesTheCallersChangeOverAnUnreadableIndex() throws {
        let (store, _) = makeStore()
        let url = temporaryFile("moments-index.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let index = MomentIndex(fileURL: url, onCorrupt: {})
        let refreshed = store.refreshDerived(reloadWidgets: false, index: index) { $0.receiptsDirty = true }
        XCTAssertFalse(refreshed.changed)
        XCTAssertTrue(store.snapshot.receiptsDirty)
    }

    // MARK: Caches (two stores on one directory stand in for two processes)

    func testCachedValuesFollowAnotherProcesssWrite() {
        let directory = temporaryFile("unused").deletingLastPathComponent().appendingPathComponent("State")
        let here = SharedStore(store: GroupFileStore(directory: directory, legacy: nil, isAppExtension: false))
        let there = SharedStore(store: GroupFileStore(directory: directory, legacy: nil, isAppExtension: true))

        here.mutate(reloadWidgets: false) { $0.lastSeenPartnerNudgeCount = 1 }
        XCTAssertEqual(here.snapshot.lastSeenPartnerNudgeCount, 1)
        XCTAssertEqual(there.snapshot.lastSeenPartnerNudgeCount, 1)
        there.mutate(reloadWidgets: false) { $0.lastSeenPartnerNudgeCount = 2 }
        XCTAssertEqual(here.snapshot.lastSeenPartnerNudgeCount, 2)

        XCTAssertTrue(here.contentFilterEnabled)
        there.contentFilterEnabled = false
        XCTAssertFalse(here.contentFilterEnabled)

        XCTAssertNil(here.hiddenPartnerStatusAt)
        there.hiddenPartnerStatusAt = Fixtures.t0
        XCTAssertEqual(here.hiddenPartnerStatusAt, Fixtures.t0)
        there.hiddenPartnerStatusAt = Fixtures.date(1)
        XCTAssertEqual(here.hiddenPartnerStatusAt, Fixtures.date(1))
        there.hiddenPartnerStatusAt = nil
        XCTAssertNil(here.hiddenPartnerStatusAt)
    }

    /// The decoded copy is a stored value, never the pre-encode one: ISO-8601
    /// drops fractions, so a cached fractional date would never match its file.
    func testCachedSnapshotIsTheDecodedCopy() {
        let (store, _) = makeStore()
        store.mutate(reloadWidgets: false) { $0.lastSyncedAt = Fixtures.date(0.6) }
        XCTAssertEqual(store.snapshot.lastSyncedAt, Fixtures.t0)
    }

    func testUnlinkDropsCorruptSidecars() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not a snapshot".utf8), forKey: "snapshot")
        defaults.set(Data("not a pairing".utf8), forKey: "pairing")
        _ = store.snapshot
        _ = store.pairing
        XCTAssertNotNil(defaults.data(forKey: "snapshot.corrupt"))
        store.clearPairing(keepingName: true)
        XCTAssertNil(defaults.data(forKey: "snapshot.corrupt"))
        XCTAssertNil(defaults.data(forKey: "pairing.corrupt"))
    }

    func testUnlinkKeepsOnlyTheName() {
        let (store, _) = makeStore()
        store.mutate(reloadWidgets: false) {
            $0.mine = Fixtures.status()
            $0.theirs = Fixtures.status()
            $0.isPaired = true
        }
        store.clearPairing(keepingName: true)
        XCTAssertEqual(store.snapshot.mine?.displayName, "Sam")
        XCTAssertNil(store.snapshot.theirs)
        XCTAssertFalse(store.snapshot.isPaired)
        store.clearPairing(keepingName: false)
        XCTAssertEqual(store.snapshot, .empty)
    }
}
