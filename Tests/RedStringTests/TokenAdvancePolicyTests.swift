import XCTest

/// Invariant 2 as `CloudSync.refresh` performs it: the change token follows
/// only what was applied and readable, and the unreadable hold's give-up starts
/// however the records were first seen.
final class TokenAdvancePolicyTests: XCTestCase {
    func testTheHoldIsNotedClearedOrKept() {
        XCTAssertEqual(TokenAdvancePolicy.holdStep(unreadable: ["a"], incomplete: false), .note(["a"]))
        XCTAssertEqual(TokenAdvancePolicy.holdStep(unreadable: ["a"], incomplete: true), .note(["a"]))
        XCTAssertEqual(TokenAdvancePolicy.holdStep(unreadable: [], incomplete: false), .clear)
        XCTAssertEqual(TokenAdvancePolicy.holdStep(unreadable: [], incomplete: true), .keep,
                       "one batch of a larger delta: the held records may be in the rest")
    }

    func testTheTokenFollowsOnlyAReadableApplyToTheSamePairing() {
        func persists(token: Bool = true, readable: Bool = true, samePairing: Bool = true,
                      hadToken: Bool = true, stillStored: Bool = true) -> Bool {
            TokenAdvancePolicy.persists(fetchedToken: token, readable: readable, samePairing: samePairing,
                                        hadToken: hadToken, tokenStillStored: stillStored)
        }
        XCTAssertTrue(persists())
        XCTAssertFalse(persists(token: false), "nothing to write")
        XCTAssertFalse(persists(readable: false), "readable before token")
        XCTAssertFalse(persists(samePairing: false), "an unlink mid-refresh: not the next pairing's cursor")
        XCTAssertFalse(persists(stillStored: false), "cleared during apply: the index is rebuilding")
        XCTAssertTrue(persists(hadToken: false, stillStored: false), "a full resync writes its first token")
    }

    // MARK: The give-up, end to end through the store

    private func makeStore() -> SharedStore { SharedStore(defaults: temporaryDefaults()) }

    /// The common order: the push wakes the notification service first, which
    /// notes the names; the app's later looks must still count to the limit.
    func testTheGiveUpStartsWhenAnExtensionSawTheRecordFirst() {
        let store = makeStore()
        let gap = AppConfig.unreadableHoldSpacing
        XCTAssertFalse(store.noteUnreadableRecords(["r"], now: Fixtures.t0, process: "notification service"))
        XCTAssertEqual(store.unreadableTally.heldStreak, 0, "an extension never counts")
        XCTAssertFalse(store.noteUnreadableRecords(["r"], now: Fixtures.date(gap)))
        XCTAssertEqual(store.unreadableTally.heldStreak, 1, "the app's first look starts the streak")
        XCTAssertFalse(store.noteUnreadableRecords(["r"], now: Fixtures.date(2 * gap)))
        XCTAssertTrue(store.noteUnreadableRecords(["r"], now: Fixtures.date(3 * gap)),
                      "three separate app looks give up, so the token can move")
    }

    /// Same, when the app's first sighting was a locked phone's background refresh.
    func testTheGiveUpStartsAfterALockedAppSighting() {
        let store = makeStore()
        let gap = AppConfig.unreadableHoldSpacing
        XCTAssertFalse(store.noteUnreadableRecords(["r"], now: Fixtures.t0, protectedData: false))
        XCTAssertEqual(store.unreadableTally.heldStreak, 0)
        XCTAssertFalse(store.noteUnreadableRecords(["r"], now: Fixtures.date(gap)))
        XCTAssertFalse(store.noteUnreadableRecords(["r"], now: Fixtures.date(2 * gap)))
        XCTAssertTrue(store.noteUnreadableRecords(["r"], now: Fixtures.date(3 * gap)))
    }
}
