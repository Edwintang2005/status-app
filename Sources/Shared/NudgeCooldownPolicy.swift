import Foundation

/// The lock-screen heart's send abandoned at its deadline (invariant 7).
enum NudgeCooldownPolicy {
    /// Releases the cooldown and stamps the failure when the standing claim is
    /// this tap's and its save never landed. `sendNudge` claims just after
    /// `started`; any later claim can only follow our cooldown, so it is another
    /// process's tap, possibly still in flight. Run inside the caller's `mutate`.
    @discardableResult
    static func releaseAbandoned(startedAt started: Date,
                                 in snapshot: inout Snapshot,
                                 now: Date = Date()) -> Bool {
        guard let claim = snapshot.lastNudgeSentAt, claim >= started,
              claim.timeIntervalSince(started) < AppConfig.nudgeCooldown,
              snapshot.mine?.lastNudgeAt != claim else { return false }
        snapshot.lastNudgeSentAt = nil
        snapshot.lastNudgeFailedAt = now
        return true
    }
}
