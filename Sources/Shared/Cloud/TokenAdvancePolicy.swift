import Foundation

/// When `CloudSync.refresh` may persist the change token — invariant 2 as a pure
/// decision, so it runs under `make test`. Records are applied first; what this
/// pass couldn't read is owed and fetched again by ID (`SharedStore.UnreadableTally`),
/// so the token moves on regardless.
enum TokenAdvancePolicy {
    /// Whether a fetched token is written.
    /// - Parameters:
    ///   - samePairing: the pairing is still the one fetched (an unlink, or an
    ///     unlink and re-pair, can land mid-refresh).
    ///   - hadToken: the fetch started from a token...
    ///   - tokenStillStored: ...and that token is still stored. One cleared during
    ///     `apply` (a corrupt index rebuilding) must not be written back.
    static func persists(samePairing: Bool,
                         hadToken: Bool,
                         tokenStillStored: Bool) -> Bool {
        guard samePairing else { return false }
        return !(hadToken && !tokenStillStored)
    }
}
