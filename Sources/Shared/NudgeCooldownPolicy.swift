import Foundation

extension Snapshot {
    /// Claims the heart's cooldown before any network call (invariant 7): `false`
    /// while the last claim is within `nudgeCooldown`. Run inside one `mutate`, so
    /// the app and the widget intent can't both pass one cooldown. `now` in whole
    /// seconds: the failure path compares it with its stored copy.
    mutating func claimNudgeCooldown(now: Date) -> Bool {
        if let last = lastNudgeSentAt, now.timeIntervalSince(last) < AppConfig.nudgeCooldown { return false }
        lastNudgeSentAt = now
        // A retry is underway; the failure notice has done its job.
        lastNudgeFailedAt = nil
        return true
    }
}

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
        // Handed to iCloud already: it lands on its own, and a "didn't send" invites a second tap.
        if let issued = snapshot.lastNudgeIssuedAt, issued >= claim { return false }
        snapshot.lastNudgeSentAt = nil
        snapshot.lastNudgeFailedAt = now
        return true
    }
}
