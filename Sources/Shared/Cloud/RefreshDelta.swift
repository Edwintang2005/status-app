import Foundation

/// One change fetch, parsed, and how it folds into `Snapshot`. No CloudKit in
/// sight so every decision here runs under `make test`; `ParsedDelta` builds it
/// from the records and `CloudSync.apply` calls `fold` inside the locked mutate.
/// A record that arrived unreadable is simply absent here: neither value nor removal.
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

    /// Both sides' `FreshStart` records, when they arrived readable or were deleted.
    var freshStart = FreshStart.Incoming()

    /// The partner's nudge counter's creation time, and its deletion.
    var partnerNudgeCreatedAt: Date?
    var partnerNudgeErased = false

    func fold(into snapshot: inout Snapshot, now: Date = Date()) {
        if let mine {
            // A status set offline is newer than the server copy; adopting the
            // server's silently reverted it. Keep the newer local text and take
            // only the server-owned nudge counter. An unpublished one always
            // stays: the fold runs before the republish, and a fast clock's
            // server copy would otherwise replace it before it's sent
            // (`StatusSavePolicy` decides there which one wins).
            if var held = snapshot.mine, !snapshot.myStatusPublished || Self.isOlder(mine, than: held, now: now) {
                held.nudgeCount = max(held.nudgeCount, mine.nudgeCount)
                held.lastNudgeAt = Self.later(held.lastNudgeAt, mine.lastNudgeAt)
                snapshot.mine = held
            } else {
                snapshot.mine = Self.merging(snapshot.mine, into: mine)
            }
        }

        if partnerErased {
            // Kept so Home can say who left and what to do, rather than "waiting".
            if let held = snapshot.theirs {
                snapshot.partnerLeftAt = now.wholeSeconds
                snapshot.partnerLeftName = held.displayName
                snapshot.partnerLeftAnnounced = false
            }
            snapshot.theirs = nil
            // A participant who unlinks and rejoins restarts their count at 1;
            // a stale watermark would swallow their next nudges.
            snapshot.lastSeenPartnerNudgeCount = 0
        } else if let theirs {
            snapshot.partnerLeftAt = nil
            snapshot.partnerLeftName = nil
            snapshot.partnerLeftAnnounced = false
            // Deltas from concurrent processes can land out of order; an older
            // copy must not regress the status, but its nudge counter is server
            // state and is taken either way — and never backwards.
            if var held = snapshot.theirs, Self.isOlder(theirs, than: held, now: now) {
                held.nudgeCount = max(held.nudgeCount, theirs.nudgeCount)
                held.lastNudgeAt = Self.later(held.lastNudgeAt, theirs.lastNudgeAt)
                snapshot.theirs = held
            } else {
                snapshot.theirs = Self.merging(snapshot.theirs, into: theirs)
            }
        }
        foldNudgeCounter(into: &snapshot)

        // The owner's own unpublished edit outranks the server copy —
        // `Outbox.republishAnniversary` carries it over. A record that arrived
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

        if !freshStart.isEmpty {
            snapshot.freshStart.fold(freshStart)
        }
    }

    /// A recreated counter restarts at 1, below the watermark: a participant
    /// who unlinked and rejoined between two fetches had every heart swallowed.
    /// A later creation time (or the counter's deletion) is a new counter,
    /// taken as it is, so its newest heart announces once; a late older copy
    /// changes nothing.
    private func foldNudgeCounter(into snapshot: inout Snapshot) {
        if partnerNudgeErased {
            snapshot.theirs?.nudgeCount = 0
            snapshot.lastSeenPartnerNudgeCount = 0
            snapshot.partnerNudgeCreatedAt = nil
        } else if let created = partnerNudgeCreatedAt {
            if let held = snapshot.partnerNudgeCreatedAt, created < held { return }
            if let held = snapshot.partnerNudgeCreatedAt, created > held, let theirs {
                snapshot.theirs?.nudgeCount = theirs.nudgeCount
                snapshot.theirs?.lastNudgeAt = theirs.lastNudgeAt
                snapshot.lastSeenPartnerNudgeCount = max(theirs.nudgeCount - 1, 0)
            }
            snapshot.partnerNudgeCreatedAt = created
        }
    }

    /// Whether `incoming` is an older copy than `held`: by server save time when
    /// both carry it (two phones' clocks can disagree by hours, the server's
    /// can't), else by `updatedAt` — where a held copy stamped in the future
    /// (a clock that ran ahead) is stale, not newer.
    static func isOlder(_ incoming: StatusPayload, than held: StatusPayload, now: Date) -> Bool {
        // Whole seconds: two saves in one second tie, and the old rule decides.
        if let saved = incoming.serverSavedAt, let heldSaved = held.serverSavedAt, saved != heldSaved {
            return saved < heldSaved
        }
        return incoming.updatedAt < held.updatedAt && !TrustedTime.isFuture(held.updatedAt, now: now)
    }

    /// `incoming`, but with a nudge count and time no lower than `held`'s: a
    /// delta built from a pre-lock snapshot must not undo another process's write.
    /// The same version keeps when its words began (a rename's echo).
    private static func merging(_ held: StatusPayload?, into incoming: StatusPayload) -> StatusPayload {
        guard let held else { return incoming }
        var merged = incoming
        merged.nudgeCount = max(held.nudgeCount, incoming.nudgeCount)
        merged.lastNudgeAt = later(held.lastNudgeAt, incoming.lastNudgeAt)
        if merged.updatedAt == held.updatedAt {
            if merged.wordsSince == nil, merged.sameWords(as: held) { merged.wordsSince = held.wordsSince }
            if merged.serverSavedAt == nil { merged.serverSavedAt = held.serverSavedAt }
        }
        return merged
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }
}
