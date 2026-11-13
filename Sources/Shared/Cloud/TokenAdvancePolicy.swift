import Foundation

/// When `CloudSync.refresh` may persist the change token — invariant 2 as a pure
/// decision, so it runs under `make test`. Records are applied first; what this
/// pass couldn't read is owed and fetched again by ID (`SharedStore.UnreadableTally`),
/// so the token moves on regardless.
enum TokenAdvancePolicy {
    /// Whether a fetched token is written: only over the bytes its fetch began
    /// from, a compare-and-swap across processes.
    /// - Parameters:
    ///   - samePairing: the pairing is still the one fetched (an unlink, or an
    ///     unlink and re-pair, can land mid-refresh).
    ///   - startedFrom: the stored token when the fetch began (`nil`: none).
    ///   - storedNow: the stored token now. Cleared during `apply` (a corrupt index
    ///     rebuilding), it must not be written back; moved by another process's
    ///     fetch, ours may be behind it — an extension's batch cursor over the
    ///     app's complete token re-downloads the zone.
    static func persists(samePairing: Bool, startedFrom: Data?, storedNow: Data?) -> Bool {
        samePairing && storedNow == startedFrom
    }
}
