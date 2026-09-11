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

    /// Records whose encrypted fields came back empty. Whatever they carried is
    /// not in this delta, so the change token must not advance past them.
    var unreadableRecords = 0

    func fold(into snapshot: inout Snapshot) {
        if let mine {
            // A status set offline is newer than the server copy; adopting the
            // server's silently reverted it. Keep the newer local text and take
            // only the server-owned nudge counter.
            if mine.updatedAt >= (snapshot.mine?.updatedAt ?? .distantPast) {
                snapshot.mine = mine
            } else {
                snapshot.mine?.nudgeCount = mine.nudgeCount
                snapshot.mine?.lastNudgeAt = mine.lastNudgeAt
            }
        }

        if partnerErased {
            snapshot.theirs = nil
        } else if let theirs {
            snapshot.theirs = theirs
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
    }
}
