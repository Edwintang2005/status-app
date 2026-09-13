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

    // MARK: Unreadable-record hold (CLAUDE.md invariant 2)

    /// The test bundle has no `NSExtension` entry, so it counts as the app —
    /// the only process allowed to give up on a record.
    func testUnreadableHoldGivesUpAfterSeparateAppRefreshes() {
        let (store, _) = makeStore()
        let t0 = Fixtures.t0
        let gap = AppConfig.unreadableHoldSpacing
        XCTAssertFalse(store.noteUnreadableRecords(["moment-owner-a"], now: t0))
        // A burst of refreshes (launch + foreground) counts once.
        XCTAssertFalse(store.noteUnreadableRecords(["moment-owner-a"], now: t0.addingTimeInterval(5)))
        XCTAssertFalse(store.noteUnreadableRecords(["moment-owner-a"], now: t0.addingTimeInterval(gap)))
        XCTAssertEqual(store.unreadableTally.heldStreak, 2)
        XCTAssertTrue(store.noteUnreadableRecords(["moment-owner-a"], now: t0.addingTimeInterval(2 * gap)),
                      "the third separate look gives up")
        let tally = store.unreadableTally
        XCTAssertEqual(tally.abandoned, 1)
        XCTAssertEqual(tally.heldStreak, 0)
        XCTAssertEqual(tally.heldNames, [])
        XCTAssertEqual(tally.counts["app"], 4, "every skip is still counted")
    }

    func testUnreadableHoldRestartsWhenTheRecordsChange() {
        let (store, _) = makeStore()
        let t0 = Fixtures.t0
        let gap = AppConfig.unreadableHoldSpacing
        XCTAssertFalse(store.noteUnreadableRecords(["a"], now: t0))
        XCTAssertFalse(store.noteUnreadableRecords(["a"], now: t0.addingTimeInterval(gap)))
        // A new unreadable record joins: not the same stuck set any more.
        XCTAssertFalse(store.noteUnreadableRecords(["a", "b"], now: t0.addingTimeInterval(2 * gap)))
        XCTAssertEqual(store.unreadableTally.heldStreak, 1)
        // A subset of what was held still counts as the same records.
        XCTAssertFalse(store.noteUnreadableRecords(["b"], now: t0.addingTimeInterval(3 * gap)))
        XCTAssertEqual(store.unreadableTally.heldStreak, 2)

        store.clearUnreadableHold()
        XCTAssertEqual(store.unreadableTally.heldStreak, 0)
        XCTAssertEqual(store.unreadableTally.heldNames, [])
        XCTAssertEqual(store.unreadableTally.counts["app"], 5, "clearing the hold keeps the evidence")
    }

    func testLegacyTallyDecodes() throws {
        let tally = try decode(SharedStore.UnreadableTally.self, #"{"counts":{"widget":3}}"#)
        XCTAssertEqual(tally.counts["widget"], 3)
        XCTAssertEqual(tally.heldStreak, 0)
        XCTAssertEqual(tally.abandoned, 0)
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

    func testZoneGoneSightingClearsWithThePairing() {
        let (store, _) = makeStore()
        XCTAssertNil(store.zoneGoneSeenAt)
        store.zoneGoneSeenAt = Fixtures.t0
        XCTAssertEqual(store.zoneGoneSeenAt, Fixtures.t0)
        store.clearPairing(keepingName: false)
        XCTAssertNil(store.zoneGoneSeenAt, "a new pairing starts with no stale sighting")
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
        store.applyDerived(from: all, reloadWidgets: false)
        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.latestOwnMoment?.id, "o1")
        XCTAssertEqual(snapshot.latestPartnerMoment?.id, "v1")
        XCTAssertEqual(snapshot.latestPartnerVisualMoment?.id, "p1", "a memo never displaces the picture")
        XCTAssertEqual(snapshot.unheardVoiceMemoCount, 1)

        store.applyDerived(from: [], reloadWidgets: false)
        XCTAssertNil(store.snapshot.latestPartnerVisualMoment, "must return to nil when the last picture goes")
        XCTAssertEqual(store.snapshot.unheardVoiceMemoCount, 0)
    }
}
