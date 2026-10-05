import Foundation

/// When `CloudSync.refresh` may persist the change token — invariant 2 as pure
/// decisions, so they run under `make test`. Records are applied first; the
/// token only follows what was readable, or what the app gave up on.
enum TokenAdvancePolicy {
    /// What a finished apply does to the unreadable-record hold.
    enum HoldStep: Equatable, Sendable {
        /// Note these names (`SharedStore.noteUnreadableRecords`), which says
        /// whether the app gives up on them.
        case note([String])
        /// Everything was read: whatever was held has resolved.
        case clear
        /// Nothing unreadable in one batch of a larger delta: the held records
        /// may be in the rest, so the hold stands.
        case keep
    }

    static func holdStep(unreadable: [String], incomplete: Bool) -> HoldStep {
        if !unreadable.isEmpty { return .note(unreadable) }
        return incomplete ? .keep : .clear
    }

    /// Whether the fetched token is written.
    /// - Parameters:
    ///   - readable: nothing unreadable, or the hold gave up on it.
    ///   - samePairing: the pairing is still the one fetched (an unlink, or an
    ///     unlink and re-pair, can land mid-refresh).
    ///   - hadToken: the fetch started from a token...
    ///   - tokenStillStored: ...and that token is still stored. One cleared during
    ///     `apply` (a corrupt index rebuilding) must not be written back.
    static func persists(fetchedToken: Bool,
                         readable: Bool,
                         samePairing: Bool,
                         hadToken: Bool,
                         tokenStillStored: Bool) -> Bool {
        guard fetchedToken, readable, samePairing else { return false }
        return !(hadToken && !tokenStillStored)
    }
}
