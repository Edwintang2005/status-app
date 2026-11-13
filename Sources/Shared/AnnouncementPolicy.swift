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
        /// The partner unlinked in this delta and no banner has said so yet.
        var partnerLeft = false
        /// Their moments removed since the last notice (`claimRemovals`).
        var removals = 0
    }

    /// What a refresh should announce. A first sight of the partner's status
    /// adopts any standing nudge count silently: it's history, not a fresh tap.
    /// The moment is whatever is owed (`Snapshot.owedMoments`) — this delta's
    /// news, or moments another pass filed and never announced (a heart or
    /// status push carried them, or the widget fetched them and their own push
    /// never came: APNs keeps one per app).
    static func claim(_ result: RefreshResult,
                      previousStatus: StatusPayload?,
                      in snapshot: inout Snapshot) -> Claims {
        var claims = Claims()
        if let theirs = result.partnerStatus,
           theirs.nudgeCount > snapshot.lastSeenPartnerNudgeCount {
            snapshot.lastSeenPartnerNudgeCount = theirs.nudgeCount
            claims.nudge = previousStatus != nil
        }
        claims.moment = takeOwedMoments(in: &snapshot)
        claims.partnerLeft = result.partnerLeft && claimPartnerLeft(in: &snapshot)
        claims.removals = claimRemovals(in: &snapshot)
        return claims
    }

    /// Every owed moment, taken: one banner for the newest to arrive — a burst
    /// is one banner, and the rest are never described later as new. Arrival
    /// order, not `sentAt`: that's the partner's clock.
    static func takeOwedMoments(in snapshot: inout Snapshot) -> Moment? {
        guard let newest = snapshot.owedMoments.last else { return nil }
        snapshot.recordTaken(snapshot.owedMoments.map(\.id))
        snapshot.owedMoments = []
        snapshot.lastNotifiedMomentID = newest.id
        return newest
    }

    /// The partner's deletions owed a notice (`Snapshot.removalNotices`), taken
    /// by whoever announces them, so one notice covers them, once.
    static func claimRemovals(in snapshot: inout Snapshot) -> Int {
        let count = snapshot.removalNotices.count
        snapshot.removalNotices = []
        return count
    }

    /// The one banner saying the partner left: `false` once claimed, or when
    /// the snapshot doesn't say they left (their status is back).
    static func claimPartnerLeft(in snapshot: inout Snapshot) -> Bool {
        guard snapshot.partnerHasLeft, !snapshot.partnerLeftAnnounced else { return false }
        snapshot.partnerLeftAnnounced = true
        return true
    }

    /// Whether an unknown moment is news. A full resync returns everything the
    /// index doesn't hold — past its cap, after a rebuild — so there only what
    /// the server created after the last complete fetch counts (`Snapshot.newsAfter`;
    /// none, after a new pairing or a reinstall). An incremental delta's unknown
    /// moment always does: a send that waited offline arrives late.
    static func isNews(createdAt: Date?, fullResync: Bool, newsAfter: Date?) -> Bool {
        guard fullResync else { return true }
        guard let createdAt, let newsAfter else { return false }
        return createdAt > newsAfter
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
        let previous = snapshot.lastAnnouncedPartnerStatus
        if let saved = status.serverSavedAt, let previousSaved = previous?.serverSavedAt, saved != previousSaved {
            // Server time when both have it: a sender whose clock ran fast
            // earlier would otherwise have every later status judged old. A
            // tie (two saves in one whole second) falls to the stamps below.
            guard saved > previousSaved else { return nil }
        } else {
            // A mark left in the future by a skewed clock would silence every later status.
            let announced = snapshot.lastAnnouncedPartnerStatusAt
                .flatMap { TrustedTime.isFuture($0, now: now) ? nil : $0 } ?? .distantPast
            guard status.updatedAt > announced else { return nil }
        }
        snapshot.lastAnnouncedPartnerStatusAt = status.updatedAt
        snapshot.lastAnnouncedPartnerStatus = status
        if let previous, previous.sameWords(as: status), previous.displayName != status.displayName {
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
        snapshot.lastBreakthroughNudgeAt = now.wholeSeconds
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
        // Deletions too: a fresh start clearing must reach the open screen.
        previousStatus != result.partnerStatus || !result.newPartnerMoments.isEmpty || result.removedMoments > 0
    }
}
