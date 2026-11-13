import XCTest

/// Invariant 2 as `CloudSync.refresh` performs it: the change token follows what
/// was applied to the pairing it was fetched for; what couldn't be read is owed
/// and fetched again by ID (`CloudSyncSeamTests`), so it never holds the token.
final class TokenAdvancePolicyTests: XCTestCase {
    func testTheTokenFollowsAnApplyToTheSamePairing() {
        let t0 = Data("t0".utf8), other = Data("other".utf8)
        func persists(samePairing: Bool = true, from: Data? = t0, now: Data? = t0) -> Bool {
            TokenAdvancePolicy.persists(samePairing: samePairing, startedFrom: from, storedNow: now)
        }
        XCTAssertTrue(persists())
        XCTAssertFalse(persists(samePairing: false), "an unlink mid-refresh: not the next pairing's cursor")
        XCTAssertFalse(persists(now: nil), "cleared during apply: the index is rebuilding")
        XCTAssertTrue(persists(from: nil, now: nil), "a full resync writes its first token")
        XCTAssertFalse(persists(now: other), "another process moved it on: ours may be behind")
        XCTAssertFalse(persists(from: nil, now: other), "nor over a sweep another process began")
    }
}
