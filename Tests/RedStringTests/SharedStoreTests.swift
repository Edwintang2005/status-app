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
        XCTAssertFalse(store.hasRequestedNotifications)
        XCTAssertNil(store.changeToken(for: "private"))
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
