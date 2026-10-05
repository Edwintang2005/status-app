import Foundation

/// What a CloudKit push's banner says and how loudly: the notification
/// service's branch table, pure so every row runs under `make test`. `decide`
/// claims against the watermarks, so it runs inside one `SharedStore.mutate`
/// (invariant 1); `NotificationService` only applies the plan.
enum PushBannerPolicy {
    /// Which subscription fired. Dispatch is by subscription, never by the
    /// delta: whichever process refreshes first consumes it.
    enum Push: Equatable, Sendable {
        case status, nudge, moment, other

        init(subscriptionID: String?) {
            switch subscriptionID {
            case CloudSync.SubscriptionID.status?: self = .status
            case CloudSync.SubscriptionID.nudge?: self = .nudge
            case CloudSync.SubscriptionID.moment?: self = .moment
            default: self = .other
            }
        }

        /// Stamped up front, so every exit carries the banner actions.
        var category: String {
            switch self {
            case .status: NotificationCategory.status
            case .nudge: NotificationCategory.nudge
            case .moment: NotificationCategory.moment
            case .other: ""
            }
        }
    }

    enum Volume: Equatable, Sendable {
        /// As CloudKit sent it.
        case asSent
        /// No sound, `.passive`: the push can't be dropped, but it isn't news.
        case quiet
        case active
        case timeSensitive
    }

    /// `nil` fields keep what CloudKit sent.
    struct Plan: Equatable, Sendable {
        var title: String?
        var body: String?
        var thread: String?
        var volume: Volume = .asSent
        /// Worded from unencrypted fields alone: stamped under
        /// `NotificationCategory.heldBannerKey` so the app's sweep supersedes it.
        var heldCategory: String?
        /// Nobody to send a heart back to.
        var dropsCategory = false
        /// The moment whose thumbnail or recording the banner attaches.
        var attachment: Moment?

        static let unchanged = Plan()
    }

    /// No pairing on this phone — an offline block, a local-only reset — while
    /// the old subscriptions are still registered: whoever wrote it is no one
    /// this phone is linked with any more.
    static var unpaired: Plan {
        Plan(title: AppConfig.appName,
             body: String(localized: "From a shared space you've left."),
             thread: "unlinked",
             volume: .quiet,
             dropsCategory: true)
    }

    /// Claims and words one push. An unclaimed push is never credited to the
    /// partner: it's our own write from another device on this account, the
    /// partner leaving, deletions, or something another process announced —
    /// unless this process couldn't read the delta (a locked phone, one batch
    /// of a large one): then the event is real and unannounced, and keeps
    /// CloudKit's words at full volume.
    static func decide(_ push: Push,
                       result: RefreshResult,
                       index: [Moment],
                       reportedAt: Date?,
                       in snapshot: inout Snapshot,
                       now: Date = Date()) -> Plan {
        let name = snapshot.moderatedPartnerName
        let couldNotRead = !result.unreadableRecordNames.isEmpty || result.incomplete
        switch push {
        case .moment:
            if let moment = AnnouncementPolicy.claimMomentBanner(delta: result.newPartnerMoments, index: index,
                                                                 in: &snapshot, now: now) {
                // `name` covers records written before the sender set a name.
                return Plan(title: moment.displaySenderName(fallback: name),
                            body: moment.displayCaption ?? moment.arrivalSummary,
                            attachment: moment)
            }
            if let body = AnnouncementPolicy.heldMomentBody(kinds: result.heldPartnerMomentKinds) {
                return held(body, category: NotificationCategory.moment, name: name)
            }
            if result.ownRecordsChanged {
                return own(String(localized: "You sent something from another device."))
            }
            if let left = partnerLeft(result, name: name, in: &snapshot) { return left }
            // Deletions fire the moment subscription too (a fresh start, an
            // unlink): with nothing new from the partner in the delta, say so quietly.
            if result.removedMoments > 0, result.newPartnerMoments.isEmpty, !result.heldPartnerStatus {
                let freshStart = snapshot.freshStart.clearedBefore != nil
                return Plan(title: AppConfig.appName,
                            body: freshStart
                                ? String(localized: "Moments were cleared for your fresh start.")
                                : String(localized: "Moments were removed from your shared space."),
                            thread: "fresh-start",
                            volume: .quiet)
            }
            return couldNotRead ? .unchanged : Plan(volume: .quiet)

        case .nudge:
            let count = result.partnerStatus?.nudgeCount ?? snapshot.theirs?.nudgeCount
            let sentAt = result.partnerStatus?.lastNudgeAt ?? snapshot.theirs?.lastNudgeAt
            if let count, AnnouncementPolicy.claimNudgeBanner(count: count, in: &snapshot) {
                let interruption = AnnouncementPolicy.nudgeInterruption(sentAt: sentAt, in: &snapshot, now: now)
                return heart(name: name, interruption: interruption)
            }
            if result.ownRecordsChanged {
                return own(String(localized: "You sent a nudge from another device."))
            }
            if let left = partnerLeft(result, name: name, in: &snapshot) { return left }
            // The nudge record wasn't in what this process could read.
            if couldNotRead { return .unchanged }
            // No count is no information — a deletion, not a tap — and never a heart.
            guard count != nil else {
                return Plan(title: AppConfig.appName,
                            body: String(localized: "Your shared space changed."),
                            volume: .quiet)
            }
            // Already announced by the app or a sibling instance: the words
            // stay, the interruption goes, so it doesn't read as a second tap.
            var plan = heart(name: name, interruption: .init(stale: false, breaksThroughFocus: false))
            plan.volume = .quiet
            return plan

        case .status:
            var banner: AnnouncementPolicy.StatusBanner?
            // An unreadable status record leaves `partnerStatus` at the *previous*
            // status; claiming that would announce old words as news.
            if let status = result.partnerStatus, !result.heldPartnerStatus {
                banner = AnnouncementPolicy.claimStatusBanner(for: status, in: &snapshot, now: now)
            }
            switch (banner, result.partnerStatus) {
            case (.rename(let previousName)?, let status?):
                let fallback = String(localized: "Your partner")
                let newName = ContentFilter.displayName(status.displayName, fallback: String(localized: "a new name"))
                return Plan(title: ContentFilter.displayName(previousName, fallback: fallback),
                            body: String(localized: "is now going by \(newName)"),
                            thread: "status-updates")
            case (.update?, let status?):
                return Plan(title: name, body: statusBody(status, reportedAt: reportedAt), thread: "status-updates")
            default:
                if result.heldPartnerStatus {
                    var plan = held(String(localized: "updated their status"),
                                    category: NotificationCategory.status, name: name)
                    plan.thread = "status-updates"
                    return plan
                }
                if result.ownRecordsChanged {
                    return own(String(localized: "You changed your status from another device."))
                }
                if let left = partnerLeft(result, name: name, in: &snapshot) { return left }
                return couldNotRead ? .unchanged : Plan(volume: .quiet)
            }

        case .other:
            // Legacy silent push or unknown subscription — the refresh already ran.
            return .unchanged
        }
    }

    /// Same rule as every screen: a reported or filtered status shows no words.
    static func statusBody(_ status: StatusPayload, reportedAt: Date?) -> String {
        let shown = status.moderated(reportedAt: reportedAt)
        if shown.message != status.message { return String(localized: "updated their status") }
        return shown.message.isEmpty ? shown.emoji : "\(shown.emoji) \(shown.message)"
    }

    /// The service's window is about 30 s from `didReceive`. What the banner's
    /// attachment download may take: the widget deadline at most, and never the
    /// last few seconds — the words must go out either way. `nil`: skip it.
    static let serviceWindow: TimeInterval = 30
    static func attachmentDeadline(elapsed: TimeInterval) -> TimeInterval? {
        let left = serviceWindow - 5 - elapsed
        guard left >= 1 else { return nil }
        return min(AppConfig.widgetDeadline, left)
    }

    // MARK: - The app's own announcements

    /// What `SyncRunner` posts after its claims — only what the user hasn't
    /// been told: a push already on screen claimed it first.
    enum AppAnnouncement: Equatable, Sendable {
        case nudge(sentAt: Date?)
        case moment(Moment)
        case partnerLeft
    }

    static func appAnnouncements(_ claims: AnnouncementPolicy.Claims,
                                 result: RefreshResult,
                                 announce: Bool) -> [AppAnnouncement] {
        guard announce else { return [] }
        var posts: [AppAnnouncement] = []
        if claims.partnerLeft { posts.append(.partnerLeft) }
        if claims.nudge { posts.append(.nudge(sentAt: result.partnerStatus?.lastNudgeAt)) }
        if let moment = claims.moment { posts.append(.moment(moment)) }
        return posts
    }

    // MARK: - Rows

    private static func held(_ body: String, category: String, name: String) -> Plan {
        Plan(title: name, body: body, heldCategory: category)
    }

    private static func own(_ body: String) -> Plan {
        Plan(title: AppConfig.appName, body: body, volume: .quiet)
    }

    /// Same wording rules as `NotificationManager.postNudge`.
    private static func heart(name: String, interruption: AnnouncementPolicy.NudgeInterruption) -> Plan {
        Plan(title: name,
             body: interruption.stale
                ? String(localized: "was thinking of you earlier 💭")
                : String(localized: "is thinking of you 💭"),
             volume: interruption.breaksThroughFocus ? .timeSensitive : .active)
    }

    /// The partner unlinked — in this delta, or in one another process already
    /// filed. Every push it fires says so, quietly; the first claims it, so the
    /// app doesn't post it again.
    private static func partnerLeft(_ result: RefreshResult, name: String, in snapshot: inout Snapshot) -> Plan? {
        guard result.partnerLeft || snapshot.partnerHasLeft else { return nil }
        _ = AnnouncementPolicy.claimPartnerLeft(in: &snapshot)
        return Plan(title: name,
                    body: String(localized: "left your shared space"),
                    thread: "partner-left",
                    volume: .quiet,
                    dropsCategory: true)
    }
}
