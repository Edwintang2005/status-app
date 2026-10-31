import Foundation

/// What to do with banners already delivered, now that more is known: the
/// pure half of `BannerUpkeep`. iOS runs nothing of ours at unlock, so every
/// refresh — app, notification service, widget, an expanded banner — asks
/// this, and whichever runs first after the phone can read tidies up.
enum BannerUpkeepPolicy {
    struct Banner: Equatable, Sendable {
        var id: String
        var subject: BannerSubject
        /// Worded from plaintext alone on a locked phone (`NotificationCategory.heldBannerKey`).
        var held: Bool
        var wantsAttachment: Bool
        var date: Date
    }

    struct State {
        /// The readable index; `nil` when it can't be read, and moments are left alone.
        var index: [Moment]?
        /// Moments whose records are still held unreadable (`UnreadableTally.heldNames`).
        var heldMomentIDs: Set<String> = []
        /// Reported moments, gone from every surface.
        var hidden: Set<String>
        /// The thumbnail or recording a banner attaches is on disk.
        var hasAttachment: (Moment) -> Bool
        /// The partner's status record is still held unreadable.
        var statusHeld: Bool
        var partnerStatus: StatusPayload?
    }

    enum Action: Equatable, Sendable {
        case remove(String)
        /// A locked-phone banner, readable now: the moment's words, and its attachment
        /// if here — if it's still unannounced once claimed (`claimReword`).
        case reword(id: String, moment: Moment)
        /// Same words; the attachment that missed the deadline is here now.
        case attach(id: String, moment: Moment)
        /// A locked-phone status banner: the current words, if they claim as news
        /// (`AnnouncementPolicy.claimStatusBanner`) — otherwise it's withdrawn.
        case rewordStatus(id: String, status: StatusPayload)
    }

    /// `incoming` is the banner about to be delivered (the service's own push),
    /// which supersedes delivered ones the same way a newer delivered one would.
    static func plan(_ banners: [Banner], state: State, incoming: BannerSubject? = nil) -> [Action] {
        var actions: [Action] = []
        if let index = state.index {
            for banner in banners {
                guard case .moment(let id) = banner.subject else { continue }
                // Reported, or the service's own push is about to say it again.
                if state.hidden.contains(id) || incoming == banner.subject {
                    actions.append(.remove(banner.id))
                    continue
                }
                guard let moment = index.first(where: { $0.id == id }) else {
                    // Held moments aren't filed until readable; anything else —
                    // a held one included, once its record is no longer held —
                    // was deleted, cleared or given up on.
                    if !banner.held || !state.heldMomentIDs.contains(id) { actions.append(.remove(banner.id)) }
                    continue
                }
                if banner.held {
                    actions.append(.reword(id: banner.id, moment: moment))
                } else if banner.wantsAttachment, state.hasAttachment(moment) {
                    actions.append(.attach(id: banner.id, moment: moment))
                }
            }
        }

        // Status banners say "is now …": only the latest is still true.
        let statuses = banners.filter { $0.subject == .status }.sorted { $0.date < $1.date }
        let superseded = incoming == .status ? statuses : Array(statuses.dropLast())
        actions += superseded.map { .remove($0.id) }
        if incoming != .status, let newest = statuses.last, newest.held,
           !state.statusHeld, let status = state.partnerStatus {
            actions.append(.rewordStatus(id: newest.id, status: status))
        }
        return actions
    }

    /// A reworded banner is its moment's announcement (invariant 10): claimed
    /// inside the caller's `mutate`, or withdrawn when another banner — or the
    /// open app — announced it first, so nothing alerts for it twice.
    static func claimReword(_ moment: Moment, in snapshot: inout Snapshot) -> Bool {
        guard !snapshot.hasAnnounced(moment.id) else { return false }
        snapshot.recordAnnounced(moment)
        return true
    }
}
