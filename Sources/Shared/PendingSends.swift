import Foundation

/// What's waiting to send, for the list behind the offline card and the
/// footer's "waiting" pill: our unsent moments (newest first), the status if
/// it's waiting, and how many other changes ride along.
struct PendingSends: Equatable {
    struct Item: Identifiable, Equatable {
        let moment: Moment
        /// Uploading now, here or from the share sheet: it may land anyway, so no "Don't send".
        let sending: Bool
        var id: String { moment.id }
    }

    var moments: [Item]
    var status: StatusPayload?
    /// Caption edits, deletes, the date: counted, not listed.
    var others: Int

    var isEmpty: Bool { moments.isEmpty && status == nil && others == 0 }

    /// `waiting`: the footer's own count (`AppModel.pendingSendCount`), which
    /// leaves out what's uploading now.
    init(history: [Moment], sending: Set<String>, status: StatusPayload?, waiting: Int) {
        let unsent = history.filter { $0.fromMe && !$0.uploaded }.sorted { $0.sentAt > $1.sentAt }
        moments = unsent.map { Item(moment: $0, sending: sending.contains($0.id)) }
        self.status = status
        let listed = moments.count { !$0.sending } + (status == nil ? 0 : 1)
        others = max(0, waiting - listed)
    }
}
