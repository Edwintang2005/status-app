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
        /// The words it shows, to tell when its moment's caption has moved on.
        var body = ""
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
        /// Every partner moment past the announced floor has been announced:
        /// a generic moment banner (`BannerSubject.newMoments`) had nothing new to say.
        var nothingUnannounced = false
        /// The bodies a banner about this moment may show now — its words, or
        /// the edited-caption notice; the first is what a stale banner becomes.
        var wordings: (Moment) -> [String] = { _ in [] }
    }

    enum Action: Equatable, Sendable {
        case remove(String)
        /// A locked-phone banner, readable now: the moment's words, and its attachment
        /// if here — if it's still unannounced once claimed (`claimReword`).
        case reword(id: String, moment: Moment)
        /// Already announced; its caption changed (an edit another pass filed),
        /// or the attachment that missed the deadline is here now. No claim.
        case refresh(id: String, moment: Moment)
        /// The newest status banner, held: the current words, if they claim as
        /// news (`AnnouncementPolicy.claimStatusBanner`). Otherwise one in
        /// CloudKit's words (`generic`) is withdrawn — it may have been our own
        /// status — and one that named the partner keeps its words, unheld.
        case rewordStatus(id: String, status: StatusPayload, generic: Bool)
    }

    /// `incoming` is the banner about to be delivered (the service's own push),
    /// which replaces a delivered one about the same moment.
    static func plan(_ banners: [Banner], state: State, incoming: BannerSubject? = nil) -> [Action] {
        var actions: [Action] = []
        if let index = state.index {
            for banner in banners {
                if banner.subject == .newMoments, state.nothingUnannounced {
                    // CloudKit's words for a push that was an edit, a deletion or our own.
                    actions.append(.remove(banner.id))
                    continue
                }
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
                let wordings = state.wordings(moment)
                if banner.held {
                    actions.append(.reword(id: banner.id, moment: moment))
                } else if (banner.wantsAttachment && state.hasAttachment(moment))
                            || (!wordings.isEmpty && !wordings.contains(banner.body)) {
                    actions.append(.refresh(id: banner.id, moment: moment))
                }
            }
        }

        // Every status banner stays: together they're the unread history. Only
        // the newest held one can be worded — the stored status is the latest;
        // an older held banner keeps "updated their status".
        let statuses = banners.filter { $0.subject == .status }
        if let newest = statuses.max(by: { $0.date < $1.date }), newest.held,
           !state.statusHeld, let status = state.partnerStatus {
            actions.append(.rewordStatus(id: newest.id, status: status,
                                         generic: newest.body == CloudSync.GenericAlert.status))
        }
        return actions
    }

    /// A push banner with no subject — its service pass never ran (killed, or
    /// before first unlock) — still in CloudKit's own words: what it's about,
    /// from its subscription, so it's handled as held. A worded one (our own
    /// echo), a heart (`postNudge` sweeps those) or anything else is left alone.
    static func inferredSubject(subscriptionID: String?, body: String) -> BannerSubject? {
        let push = PushBannerPolicy.Push(subscriptionID: subscriptionID)
        let generic: String? = switch push {
        case .status: CloudSync.GenericAlert.status
        case .moment: CloudSync.GenericAlert.moment
        case .nudge, .other: nil
        }
        guard let generic, body == generic else { return nil }
        return push.unwordedSubject
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
