import Foundation

/// The check-and-claim decisions behind every notification, against the
/// watermarks in `Snapshot`. Callers run these *inside* one `SharedStore.mutate`
/// (CLAUDE.md invariant 1) — the app, widget and notification service all
/// advance the same marks, and a claim outside the lock double-announced.
enum AnnouncementPolicy {
    struct Claims: Equatable, Sendable {
        /// The partner's nudge count moved past the watermark.
        var nudge = false
        /// The newest partner moment in the delta not yet announced.
        var moment: Moment?
    }

    /// What a refresh should announce. A first sight of the partner's status
    /// adopts any standing nudge count silently: it's history, not a fresh tap.
    static func claim(_ result: RefreshResult,
                      previousStatus: StatusPayload?,
                      in snapshot: inout Snapshot) -> Claims {
        var claims = Claims()
        if let theirs = result.partnerStatus,
           theirs.nudgeCount > snapshot.lastSeenPartnerNudgeCount {
            snapshot.lastSeenPartnerNudgeCount = theirs.nudgeCount
            claims.nudge = previousStatus != nil
        }
        // Only the newest, even if several arrived at once.
        if let moment = result.newestPartnerMoment, !snapshot.hasAnnounced(moment.id) {
            snapshot.recordAnnounced(moment.id)
            claims.moment = moment
        }
        return claims
    }

    /// Whether a status push may rewrite its banner: judged by watermark, not by
    /// "did *my* refresh see the change" — the widget often consumes the delta first.
    static func claimStatusBanner(for status: StatusPayload, in snapshot: inout Snapshot) -> Bool {
        let announced = snapshot.lastAnnouncedPartnerStatusAt ?? .distantPast
        guard status.updatedAt > announced else { return false }
        snapshot.lastAnnouncedPartnerStatusAt = status.updatedAt
        return true
    }

    /// The moment a push banner should describe: the newest un-announced one from
    /// this refresh's delta, then from the index, then the newest at all. Rapid
    /// pushes run as concurrent extension instances and must not claim the same one.
    static func claimMomentBanner(delta: [Moment],
                                  index: [Moment],
                                  in snapshot: inout Snapshot) -> Moment? {
        let fromDelta = delta.sorted { $0.sentAt > $1.sentAt }
        let fromIndex = index.filter { !$0.fromMe }
        let chosen = fromDelta.first { !snapshot.hasAnnounced($0.id) }
            ?? fromIndex.first { !snapshot.hasAnnounced($0.id) }
            ?? fromDelta.first
            ?? fromIndex.first
        if let chosen { snapshot.recordAnnounced(chosen.id) }
        return chosen
    }

    /// Whether the refresh changed anything the user would notice.
    static func changed(_ result: RefreshResult, previousStatus: StatusPayload?) -> Bool {
        previousStatus != result.partnerStatus || !result.newPartnerMoments.isEmpty
    }
}
