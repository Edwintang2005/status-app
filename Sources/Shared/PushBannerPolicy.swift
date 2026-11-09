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

        /// What a banner still in CloudKit's words is about (the fetch failed, ran
        /// out of time or couldn't read): stamped held, so a later refresh rewords
        /// or withdraws it (`BannerUpkeep`). A moment push doesn't name its
        /// moment: withdrawn once nothing is left unannounced (an edit, a
        /// deletion), else the app's sweep replaces it when it posts the moment.
        var unwordedSubject: BannerSubject? {
            switch self {
            case .status: .status
            case .moment: .newMoments
            case .nudge, .other: nil
            }
        }
    }

    enum Volume: Equatable, Sendable {
        /// As CloudKit sent it.
        case asSent
        /// No sound, `.passive`: the push can't be dropped, but it isn't news.
        case quiet
        /// A banner with no sound that never breaks through Focus: the
        /// receiver's choice (`NotificationPreferences`).
        case silent
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
        /// What the banner is about, for `BannerUpkeep` to find it again.
        var subject: BannerSubject?
        /// Adds the default sound: the status subscription was registered silent
        /// and can't change in place. Only once the plan knows it's the partner's
        /// status — an unworded or failed pass may be our own save coming back.
        var sound = false

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
                            attachment: moment,
                            subject: .moment(moment.id))
            }
            if let body = AnnouncementPolicy.heldMomentBody(kinds: result.heldPartnerMomentKinds) {
                var plan = held(body, category: NotificationCategory.moment, name: name)
                // The newest of a burst: once readable, the banner names it, as a claim would.
                plan.subject = result.heldPartnerMomentIDs.last.map(BannerSubject.moment)
                return plan
            }
            // Announced like the moment was: they took back something you may have seen.
            let removed = AnnouncementPolicy.claimRemovals(in: &snapshot)
            if removed > 0 {
                return Plan(title: name, body: removalBody(count: removed), thread: "moment-removals")
            }
            // Quiet: the moment was announced when it came. Its subject replaces
            // the banner still showing the old words (`BannerUpkeep`).
            if let edited = result.editedPartnerMoments.last {
                return Plan(title: edited.displaySenderName(fallback: name),
                            body: editedCaptionBody(edited),
                            volume: .quiet,
                            subject: .moment(edited.id))
            }
            if result.ownMomentEdited {
                return own(String(localized: "You edited a caption from another device."))
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
            return couldNotRead ? .unchanged : momentAlreadyKnown(result, snapshot, name: name, now: now)

        case .nudge:
            let count = result.partnerStatus?.nudgeCount ?? snapshot.theirs?.nudgeCount
            let sentAt = result.partnerStatus?.lastNudgeAt ?? snapshot.theirs?.lastNudgeAt
            if let count, AnnouncementPolicy.claimNudgeBanner(count: count, in: &snapshot) {
                let interruption = AnnouncementPolicy.nudgeInterruption(sentAt: sentAt, in: &snapshot, now: now)
                return heart(name: name, interruption: interruption)
            }
            // Our tap, never their heart: only our record moved, or nothing new
            // was read (the widget's own refresh took our save before its push
            // came) and the latest heart in the space is ours.
            if !result.partnerNudgeArrived,
               let sentAt = result.ownNudgeSentAt ?? (couldNotRead ? nil : ourLatestHeart(in: snapshot)) {
                return isThisPhones(sentAt, snapshot)
                    ? own(String(localized: "Your nudge was sent to \(name)."))
                    : own(String(localized: "You sent a nudge from another device."))
            }
            if result.ownRecordsChanged {
                return own(String(localized: "You sent a nudge from another device."))
            }
            if let left = partnerLeft(result, name: name, in: &snapshot) { return left }
            // The nudge record wasn't in what this process could read.
            if couldNotRead { return .unchanged }
            // No count is no information — a deletion, not a tap — and never a heart.
            guard count != nil else { return spaceChanged }
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
                // No subject: it's about a name, not words, so status upkeep leaves it be.
                return Plan(title: ContentFilter.displayName(previousName, fallback: fallback),
                            body: String(localized: "is now going by \(newName)"),
                            thread: "status-updates",
                            sound: true)
            case (.update?, let status?):
                return Plan(title: name,
                            body: statusBody(status, reportedAt: reportedAt, sealed: snapshot.partnerStatusSealed),
                            thread: "status-updates",
                            subject: .status,
                            sound: true)
            default:
                if result.heldPartnerStatus {
                    var plan = held(String(localized: "updated their status"),
                                    category: NotificationCategory.status, name: name)
                    plan.thread = "status-updates"
                    plan.subject = .status
                    plan.sound = true
                    return plan
                }
                if result.ownRecordsChanged {
                    return own(String(localized: "You changed your status from another device."))
                }
                if let left = partnerLeft(result, name: name, in: &snapshot) { return left }
                return couldNotRead ? .unchanged : statusAlreadyKnown(snapshot, name: name, reportedAt: reportedAt)
            }

        case .other:
            // Legacy silent push or unknown subscription — the refresh already ran.
            return .unchanged
        }
    }

    /// A heart or status push whose pass also filed partner moments: their own
    /// push may never come (APNs keeps one notification per app for an offline
    /// phone), so the newest is claimed here — in the same `mutate` as `decide`
    /// — for the service to announce beside this push's own banner. The app's
    /// rule for a delta's news, so a burst is one banner.
    static func carriedMoment(_ push: Push, result: RefreshResult,
                              in snapshot: inout Snapshot, now: Date = Date()) -> Moment? {
        guard push == .nudge || push == .status else { return nil }
        let floor = snapshot.lastAnnouncedMomentSentAt
        let news = result.newPartnerMoments.filter {
            AnnouncementPolicy.isNews($0, fullResync: result.fullResync, floor: floor, now: now)
        }
        let chosen = news.last { !snapshot.hasAnnounced($0.id) }
        for moment in news { snapshot.recordAnnounced(moment) }
        return chosen
    }

    /// Same rule as every screen: a reported or filtered status shows no words,
    /// and an unopened surprise keeps them for the app.
    static func statusBody(_ status: StatusPayload, reportedAt: Date?, sealed: Bool = false) -> String {
        if sealed, status.moderation(reportedAt: reportedAt, sealed: true) == .sealed {
            return String(localized: "🎁 has a surprise for you — open \(AppConfig.appName) to see it")
        }
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
        case removed(count: Int)
    }

    static func appAnnouncements(_ claims: AnnouncementPolicy.Claims,
                                 result: RefreshResult,
                                 announce: Bool) -> [AppAnnouncement] {
        guard announce else { return [] }
        var posts: [AppAnnouncement] = []
        if claims.partnerLeft { posts.append(.partnerLeft) }
        if claims.nudge { posts.append(.nudge(sentAt: result.partnerStatus?.lastNudgeAt)) }
        if let moment = claims.moment { posts.append(.moment(moment)) }
        if claims.removals > 0 { posts.append(.removed(count: claims.removals)) }
        return posts
    }

    // MARK: - Rows

    /// Nothing new from the partner in what this process read: this phone's own
    /// send coming back, or something already announced. Quiet, never CloudKit's
    /// "sent you something" for our own send. "Sent" needs our record in the
    /// delta — or, with nothing read (another process took it), our newest
    /// moment uploaded, just now, and newer than theirs.
    private static func momentAlreadyKnown(_ result: RefreshResult, _ snapshot: Snapshot,
                                           name: String, now: Date) -> Plan {
        let sent = own(String(localized: "Your moment was sent to \(name)."))
        if result.ownMomentSent { return sent }
        if result.ownCaptionEditSent { return own(String(localized: "Your caption edit was sent to \(name).")) }
        let theirs = snapshot.latestPartnerMoment
        if !result.momentsArrived, let ours = snapshot.latestOwnMoment, ours.uploaded,
           ours.sentAt > (theirs?.sentAt ?? .distantPast),
           now.timeIntervalSince(ours.sentAt) <= AppConfig.nudgeEchoWindow {
            return sent
        }
        guard let theirs, snapshot.hasAnnounced(theirs.id) else { return spaceChanged }
        // With its picture: by subject it replaces the banner that showed it.
        return Plan(title: theirs.displaySenderName(fallback: name),
                    body: theirs.displayCaption ?? theirs.arrivalSummary,
                    volume: .quiet,
                    attachment: theirs,
                    subject: .moment(theirs.id))
    }

    /// The status twin: our own save coming back, or their status already announced.
    /// Server save times order the two when both carry them (`claimStatusBanner`).
    private static func statusAlreadyKnown(_ snapshot: Snapshot, name: String, reportedAt: Date?) -> Plan {
        let theirs = snapshot.theirs
        if let mine = snapshot.mine, mine.updatedAt > .distantPast {
            let oursIsNewer: Bool
            if let saved = mine.serverSavedAt, let theirSaved = theirs?.serverSavedAt {
                oursIsNewer = saved > theirSaved
            } else {
                oursIsNewer = mine.updatedAt > (theirs?.updatedAt ?? .distantPast)
            }
            if oursIsNewer { return own(String(localized: "Your status was sent to \(name).")) }
        }
        guard let theirs else { return spaceChanged }
        return Plan(title: name,
                    body: statusBody(theirs, reportedAt: reportedAt, sealed: snapshot.partnerStatusSealed),
                    thread: "status-updates",
                    volume: .quiet,
                    subject: .status)
    }

    private static var spaceChanged: Plan {
        Plan(title: AppConfig.appName, body: String(localized: "Your shared space changed."), volume: .quiet,
             dropsCategory: true)
    }

    private static func held(_ body: String, category: String, name: String) -> Plan {
        Plan(title: name, body: body, heldCategory: category)
    }

    private static func ourLatestHeart(in snapshot: Snapshot) -> Date? {
        guard let ours = snapshot.mine?.lastNudgeAt else { return nil }
        if let theirs = snapshot.theirs?.lastNudgeAt, theirs >= ours { return nil }
        return ours
    }

    /// At or up to `nudgeEchoWindow` before this phone's latest tap: the push of
    /// one of a burst of slow taps lands after the later taps moved the claim.
    private static func isThisPhones(_ sentAt: Date, _ snapshot: Snapshot) -> Bool {
        guard let latest = snapshot.lastNudgeSentAt ?? snapshot.lastNudgeIssuedAt else { return false }
        let gap = latest.wholeSeconds.timeIntervalSince(sentAt.wholeSeconds)
        return gap >= 0 && gap <= AppConfig.nudgeEchoWindow
    }

    static func removalBody(count: Int) -> String {
        count == 1 ? String(localized: "removed a moment") : String(localized: "removed \(count) moments")
    }

    /// Through the moderation helpers like every caption: a filtered one shows no words.
    static func editedCaptionBody(_ moment: Moment) -> String {
        guard let shown = moment.moderatedCaption(revealed: false) else { return String(localized: "removed a caption") }
        return shown.isPlaceholder ? String(localized: "edited a caption") : String(localized: "edited a caption: \(shown.text)")
    }

    /// Our own doing: nothing of the partner's to reply to or heart back.
    private static func own(_ body: String) -> Plan {
        Plan(title: AppConfig.appName, body: body, volume: .quiet, dropsCategory: true)
    }

    /// Same wording rules as `NotificationManager.postNudge`.
    private static func heart(name: String, interruption: AnnouncementPolicy.NudgeInterruption) -> Plan {
        Plan(title: name,
             body: interruption.stale
                ? String(localized: "was thinking of you earlier 💭")
                : String(localized: "is thinking of you 💭"),
             thread: NotificationThread.hearts,
             volume: interruption.breaksThroughFocus ? .timeSensitive : .active,
             subject: .hearts)
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
