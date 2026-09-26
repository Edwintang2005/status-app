import Foundation

/// One change fetch, parsed, and how it folds into `Snapshot`. No CloudKit in
/// sight so every decision here runs under `make test`; `CloudSync.apply` does
/// the record parsing and calls `fold` inside the locked mutate.
struct RefreshDelta: Sendable, Equatable {
    /// Own status, already merged with the nudge counter (`CloudSync.payload(from:)`).
    var mine: StatusPayload?
    var theirs: StatusPayload?
    /// The partner deleted their status record — how a participant unlinks.
    var partnerErased = false

    /// The anniversary record, when it arrived readable.
    var anniversary: Anniversary?
    var anniversaryErased = false

    /// The partner's receipt record arrived readable; `statusSeen` is then
    /// authoritative, `nil` included (receipts off, or a new status not yet seen).
    var receiptReadable = false
    var statusSeen: StatusSeen?

    /// The `AnniversaryRequest` record, when it arrived readable, and its deletion.
    var anniversaryRequestedAt: Date?
    var anniversaryRequestErased = false

    /// Records whose encrypted fields came back empty. Whatever they carried is
    /// not in this delta, so the change token must not advance past them.
    var unreadableRecords = 0

    func fold(into snapshot: inout Snapshot, now: Date = Date()) {
        if let mine {
            // A status set offline is newer than the server copy; adopting the
            // server's silently reverted it. Keep the newer local text and take
            // only the server-owned nudge counter. A held copy stamped in the
            // future (a clock that ran ahead) is stale, not newer.
            if var held = snapshot.mine, mine.updatedAt < held.updatedAt,
               !TrustedTime.isFuture(held.updatedAt, now: now) {
                held.nudgeCount = max(held.nudgeCount, mine.nudgeCount)
                held.lastNudgeAt = Self.later(held.lastNudgeAt, mine.lastNudgeAt)
                snapshot.mine = held
            } else {
                snapshot.mine = Self.keepingNudges(of: snapshot.mine, in: mine)
            }
        }

        if partnerErased {
            snapshot.theirs = nil
            // A participant who unlinks and rejoins restarts their count at 1;
            // a stale watermark would swallow their next nudges.
            snapshot.lastSeenPartnerNudgeCount = 0
        } else if let theirs {
            // Deltas from concurrent processes can land out of order; an older
            // copy must not regress the status, but its nudge counter is server
            // state and is taken either way — and never backwards.
            if var held = snapshot.theirs, theirs.updatedAt < held.updatedAt,
               !TrustedTime.isFuture(held.updatedAt, now: now) {
                held.nudgeCount = max(held.nudgeCount, theirs.nudgeCount)
                held.lastNudgeAt = Self.later(held.lastNudgeAt, theirs.lastNudgeAt)
                snapshot.theirs = held
            } else {
                snapshot.theirs = Self.keepingNudges(of: snapshot.theirs, in: theirs)
            }
        }

        // The owner's own unpublished edit outranks the server copy —
        // `republishAnniversaryIfNeeded` carries it over. A record that arrived
        // unreadable is neither value nor removal: only a deletion clears the date.
        if snapshot.anniversaryPublished {
            if anniversaryErased {
                snapshot.anniversary = nil
            } else if let anniversary {
                snapshot.anniversary = anniversary
            }
        }

        if receiptReadable {
            snapshot.myStatusSeenByPartner = statusSeen
        }

        // Same shape as the anniversary: the participant's own unpublished ask
        // outranks the server copy; unreadable is neither value nor removal.
        if snapshot.anniversaryRequestPublished {
            if anniversaryRequestErased {
                snapshot.anniversaryRequestedAt = nil
            } else if let anniversaryRequestedAt {
                snapshot.anniversaryRequestedAt = anniversaryRequestedAt
            }
        }
    }

    /// `incoming`, but with a nudge count and time no lower than `held`'s: a
    /// delta built from a pre-lock snapshot must not undo another process's write.
    private static func keepingNudges(of held: StatusPayload?, in incoming: StatusPayload) -> StatusPayload {
        guard let held else { return incoming }
        var merged = incoming
        merged.nudgeCount = max(held.nudgeCount, incoming.nudgeCount)
        merged.lastNudgeAt = later(held.lastNudgeAt, incoming.lastNudgeAt)
        return merged
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }
}
