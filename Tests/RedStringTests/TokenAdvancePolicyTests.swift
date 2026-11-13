import XCTest

/// Invariant 2 as `CloudSync.refresh` performs it: the change token follows what
/// was applied to the pairing it was fetched for; what couldn't be read is owed
/// and fetched again by ID (`CloudSyncSeamTests`), so it never holds the token.
final class TokenAdvancePolicyTests: XCTestCase {
    func testTheTokenFollowsAnApplyToTheSamePairing() {
        func persists(samePairing: Bool = true, hadToken: Bool = true, stillStored: Bool = true) -> Bool {
            TokenAdvancePolicy.persists(samePairing: samePairing, hadToken: hadToken, tokenStillStored: stillStored)
        }
        XCTAssertTrue(persists())
        XCTAssertFalse(persists(samePairing: false), "an unlink mid-refresh: not the next pairing's cursor")
        XCTAssertFalse(persists(stillStored: false), "cleared during apply: the index is rebuilding")
        XCTAssertTrue(persists(hadToken: false, stillStored: false), "a full resync writes its first token")
    }
}
