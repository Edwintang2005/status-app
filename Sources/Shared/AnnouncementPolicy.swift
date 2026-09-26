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
        // One notification for the newest, but every moment in the burst is
        // marked announced — otherwise the push banner's index fallback would
        // later describe an older one from this batch as new.
        if let moment = result.newestPartnerMoment, !snapshot.hasAnnounced(moment.id) {
            claims.moment = moment
        }
        for moment in result.newPartnerMoments { snapshot.recordAnnounced(moment) }
        return claims
    }

    /// What a status push banner should say, or `nil` when this status has
    /// already been announced (another process claimed it first).
    enum StatusBanner: Equatable, Sendable {
        case update
        /// Same words, new name: the partner renamed themselves.
        case rename(previousName: String)
    }

    /// Whether a status push may rewrite its banner: judged by watermark, not by
    /// "did *my* refresh see the change" — the widget often consumes the delta
    /// first. The rename check compares against the last *announced* status for
    /// the same reason: a pre-refresh snapshot is already current in that case.
    static func claimStatusBanner(for status: StatusPayload,
                                  in snapshot: inout Snapshot,
                                  now: Date = Date()) -> StatusBanner? {
        // A mark left in the future by a skewed clock would silence every later status.
        let announced = snapshot.lastAnnouncedPartnerStatusAt
            .flatMap { TrustedTime.isFuture($0, now: now) ? nil : $0 } ?? .distantPast
        guard status.updatedAt > announced else { return nil }
        let previous = snapshot.lastAnnouncedPartnerStatus
        snapshot.lastAnnouncedPartnerStatusAt = status.updatedAt
        snapshot.lastAnnouncedPartnerStatus = status
        if let previous,
           previous.emoji == status.emoji,
           previous.message == status.message,
           previous.isCelebration == status.isCelebration,
           previous.displayName != status.displayName {
            return .rename(previousName: previous.displayName)
        }
        return .update
    }

    /// Whether a nudge push may announce: the partner's count moved past the
    /// watermark. `max`, not assignment — concurrent instances land out of order.
    static func claimNudgeBanner(count: Int, in snapshot: inout Snapshot) -> Bool {
        guard count > snapshot.lastSeenPartnerNudgeCount else { return false }
        snapshot.lastSeenPartnerNudgeCount = count
        return true
    }

    /// The moment a push banner should describe: the newest un-announced one from
    /// this refresh's delta, then from the index — but only newer than anything
    /// already announced, so a history re-fetched wholesale (the ids list holds
    /// eight) is never mistaken for news. `nil` when there is nothing: the
    /// generic wording beats re-describing an old moment. Rapid pushes run as
    /// concurrent extension instances and must not claim the same one.
    static func claimMomentBanner(delta: [Moment],
                                  index: [Moment],
                                  in snapshot: inout Snapshot,
                                  now: Date = Date()) -> Moment? {
        // A floor stuck in the future is read as *now*, not as no floor: the
        // index fallback must still never re-describe an old moment as new.
        let floor = snapshot.lastAnnouncedMomentSentAt
            .map { TrustedTime.isFuture($0, now: now) ? now : $0 } ?? .distantPast
        let fromDelta = delta.sorted { $0.sentAt > $1.sentAt }
        let fromIndex = index.filter { !$0.fromMe && $0.sentAt > floor }
        let chosen = fromDelta.first { !snapshot.hasAnnounced($0.id) }
            ?? fromIndex.first { !snapshot.hasAnnounced($0.id) }
        if let chosen { snapshot.recordAnnounced(chosen) }
        return chosen
    }

    /// How loudly a nudge may interrupt. Fresh (sent within
    /// `AppConfig.nudgeStaleAfter`) and the first in `nudgeBreakthroughInterval`:
    /// time-sensitive, through Focus. Otherwise an ordinary alert — a partner
    /// tapping repeatedly, or a push delivered hours late, can't keep piercing
    /// Focus. Claims the breakthrough inside the caller's `mutate`.
    struct NudgeInterruption: Equatable, Sendable {
        var stale: Bool
        var breaksThroughFocus: Bool
    }

    static func nudgeInterruption(sentAt: Date?,
                                  in snapshot: inout Snapshot,
                                  now: Date = Date()) -> NudgeInterruption {
        let stale = sentAt.map { now.timeIntervalSince($0) > AppConfig.nudgeStaleAfter } ?? false
        guard !stale else { return NudgeInterruption(stale: true, breaksThroughFocus: false) }
        if let last = snapshot.lastBreakthroughNudgeAt,
           !TrustedTime.isFuture(last, now: now),
           now.timeIntervalSince(last) < AppConfig.nudgeBreakthroughInterval {
            return NudgeInterruption(stale: false, breaksThroughFocus: false)
        }
        snapshot.lastBreakthroughNudgeAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return NudgeInterruption(stale: false, breaksThroughFocus: true)
    }

    /// A locked phone's moment banner body, from what travels unencrypted: the
    /// kinds of the partner's undecryptable new moments. Several can't be matched
    /// to this one push, so the kind is named only when they all agree. `nil`
    /// when none are the partner's — CloudKit's generic wording stays.
    static func heldMomentBody(kinds: [Moment.Kind]) -> String? {
        guard let first = kinds.first else { return nil }
        guard kinds.allSatisfy({ $0 == first }) else { return String(localized: "sent you something 📷") }
        return first.arrivalSummary
    }

    /// Whether the refresh changed anything the user would notice.
    static func changed(_ result: RefreshResult, previousStatus: StatusPayload?) -> Bool {
        previousStatus != result.partnerStatus || !result.newPartnerMoments.isEmpty
    }
}
