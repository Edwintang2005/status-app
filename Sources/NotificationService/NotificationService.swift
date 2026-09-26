import CloudKit
import UserNotifications
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Handles CloudKit's visible pushes (which survive force-quit) in the ~30s
/// mutable-content window: fetch, decrypt on-device, update the App Group and
/// widget, and replace the generic wording — CloudKit can't read the encrypted fields.
final class NotificationService: UNNotificationServiceExtension {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "NotificationService")

    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// Its own copy, never the one `enrich` is rewriting — expiry must not
    /// deliver a half-rewritten banner.
    private var fallback: UNMutableNotificationContent?
    private var work: Task<Void, Never>?
    private let deliveryLock = NSLock()
    private var delivered = false

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        // Category up front, so every exit — enriched, unclaimed, refresh failed,
        // or the expiry fallback — carries the banner actions.
        let category = Self.category(for: request.content.userInfo)
        let fallback = request.content.mutableCopy() as? UNMutableNotificationContent
        fallback?.categoryIdentifier = category
        self.fallback = fallback
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        mutable?.categoryIdentifier = category

        work = Task { [weak self] in
            guard let self else { return }
            let enriched = await self.enrich(mutable, userInfo: request.content.userInfo)
            self.deliver(enriched ?? request.content)
        }
    }

    /// Out of time — show CloudKit's generic version rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        // The refresh may have landed records before the deadline — reload anyway.
        SharedStore.reloadWidgets()
        if let fallback {
            deliver(fallback)
        }
    }

    /// Exactly one delivery, whichever of the Task and the expiry gets here first.
    private func deliver(_ content: UNNotificationContent) {
        deliveryLock.lock()
        let first = !delivered
        delivered = true
        deliveryLock.unlock()
        guard first else { return }
        contentHandler?(content)
    }

    private static func category(for userInfo: [AnyHashable: Any]) -> String {
        switch CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID {
        case CloudSync.SubscriptionID.status?: return NotificationCategory.status
        case CloudSync.SubscriptionID.nudge?: return NotificationCategory.nudge
        case CloudSync.SubscriptionID.moment?: return NotificationCategory.moment
        default: return ""
        }
    }

    // MARK: - Enrichment

    private func enrich(_ content: UNMutableNotificationContent?,
                        userInfo: [AnyHashable: Any]) async -> UNNotificationContent? {
        guard let content else { return nil }
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return content
        }

        // Deferred so it runs on *every* exit — a refresh that throws midway
        // may still have applied records, and the widget must not miss them.
        defer { SharedStore.reloadWidgets() }

        let result: RefreshResult
        do {
            result = try await CloudSync.shared.refresh()
        } catch {
            log.error("Refresh failed in service extension: \(error.localizedDescription)")
            return content
        }

        let (partnerName, reportedAt) = await MainActor.run {
            (SharedStore.shared.snapshot.moderatedPartnerName, SharedStore.shared.hiddenPartnerStatusAt)
        }

        // Dispatch by subscriptionID, never by the sync delta: whichever
        // process refreshes first consumes the delta, so it can't classify the
        // push. Each branch claims against the watermarks; an unclaimed push is
        // either our own write from another device on this account, or an event
        // some other process already announced — neither is news from the partner.
        // Unless this process simply couldn't decrypt the delta (a locked phone),
        // or only took the first batch of a large one: then the event is real
        // and unannounced, and CloudKit's generic words must stay at full volume.
        let couldNotRead = !result.unreadableRecordNames.isEmpty || result.incomplete
        // Out of time: the expiry fallback is (or is about to be) delivered, and
        // a claim now would mark announced an event whose rich banner never shows.
        if Task.isCancelled { return content }
        switch notification.subscriptionID {
        case CloudSync.SubscriptionID.moment?:
            // Picked and claimed inside one `mutate` under the cross-process lock —
            // see `AnnouncementPolicy.claimMomentBanner`.
            let fromDelta = result.newPartnerMoments
            let fromIndex = MomentIndex.shared.load()
            let moment = await MainActor.run { () -> Moment? in
                var chosen: Moment?
                _ = SharedStore.shared.mutate(reloadWidgets: false) {
                    chosen = AnnouncementPolicy.claimMomentBanner(delta: fromDelta, index: fromIndex, in: &$0)
                }
                return chosen
            }
            if let moment {
                await apply(moment, to: content, partnerName: partnerName)
            } else if let body = AnnouncementPolicy.heldMomentBody(kinds: result.heldPartnerMomentKinds) {
                applyHeld(body, category: NotificationCategory.moment, to: content, partnerName: partnerName)
            } else {
                applyUnclaimed(to: content, ownWrite: result.ownRecordsChanged, couldNotRead: couldNotRead,
                               ownBody: String(localized: "You sent something from another device."))
            }
        case CloudSync.SubscriptionID.nudge?:
            let count: Int? = if let known = result.partnerStatus?.nudgeCount {
                known
            } else {
                await MainActor.run { SharedStore.shared.snapshot.theirs?.nudgeCount }
            }
            let sentAt: Date? = if let known = result.partnerStatus?.lastNudgeAt {
                known
            } else {
                await MainActor.run { SharedStore.shared.snapshot.theirs?.lastNudgeAt }
            }
            let claim = await MainActor.run { () -> AnnouncementPolicy.NudgeInterruption? in
                guard let count else { return nil }
                var interruption: AnnouncementPolicy.NudgeInterruption?
                _ = SharedStore.shared.mutate(reloadWidgets: false) {
                    guard AnnouncementPolicy.claimNudgeBanner(count: count, in: &$0) else { return }
                    interruption = AnnouncementPolicy.nudgeInterruption(sentAt: sentAt, in: &$0)
                }
                return interruption
            }
            if let claim {
                applyNudge(to: content, partnerName: partnerName, interruption: claim)
            } else if result.ownRecordsChanged {
                applyUnclaimed(to: content, ownWrite: true, couldNotRead: false,
                               ownBody: String(localized: "You sent a nudge from another device."))
            } else if couldNotRead {
                // The nudge record wasn't in what this process could read (one
                // batch of a large delta): real and unannounced, so full volume.
            } else {
                // Already announced by the app or a sibling instance: keep the
                // words, drop the interruption so it doesn't read as a second tap.
                applyNudge(to: content, partnerName: partnerName,
                           interruption: .init(stale: false, breaksThroughFocus: false))
                quieten(content)
            }
        case CloudSync.SubscriptionID.status?:
            // Check-and-claim in one `mutate` under the cross-process lock so
            // concurrent pushes don't both rewrite — see `AnnouncementPolicy.claimStatusBanner`.
            var banner: AnnouncementPolicy.StatusBanner?
            // An unreadable status record leaves `partnerStatus` at the *previous*
            // status; claiming that would announce old words as news.
            if let status = result.partnerStatus, !result.heldPartnerStatus {
                banner = await MainActor.run { () -> AnnouncementPolicy.StatusBanner? in
                    var claimed: AnnouncementPolicy.StatusBanner?
                    _ = SharedStore.shared.mutate(reloadWidgets: false) {
                        claimed = AnnouncementPolicy.claimStatusBanner(for: status, in: &$0)
                    }
                    return claimed
                }
            }
            switch (banner, result.partnerStatus) {
            case (.rename(let previousName)?, let status?):
                applyRename(status, to: content, previousName: previousName)
            case (.update?, let status?):
                applyStatus(status, to: content, partnerName: partnerName, reportedAt: reportedAt)
            default:
                if result.heldPartnerStatus {
                    applyHeld(String(localized: "updated their status"), category: NotificationCategory.status,
                              to: content, partnerName: partnerName)
                    content.threadIdentifier = "status-updates"
                } else {
                    applyUnclaimed(to: content, ownWrite: result.ownRecordsChanged, couldNotRead: couldNotRead,
                                   ownBody: String(localized: "You changed your status from another device."))
                }
            }
        default:
            // Legacy silent push or unknown subscription — the refresh already ran.
            break
        }

        return content
    }

    /// Nothing claimable. Our own write from a second device on this account
    /// says so; an event another process already announced keeps CloudKit's
    /// generic words but stops interrupting — the push itself can't be dropped.
    /// A delta this process couldn't decrypt is left exactly as CloudKit sent
    /// it: the partner's event is real, and nobody else has announced it.
    private func applyUnclaimed(to content: UNMutableNotificationContent,
                                ownWrite: Bool,
                                couldNotRead: Bool,
                                ownBody: String) {
        if ownWrite {
            content.title = AppConfig.appName
            content.body = ownBody
            quieten(content)
        } else if !couldNotRead {
            quieten(content)
        }
    }

    /// Couldn't decrypt, but the record's name says it's the partner's: their
    /// name and what the unencrypted fields allow, at full volume — nobody else
    /// can have announced it. Stamped so the app's sweep supersedes it later.
    private func applyHeld(_ body: String,
                           category: String,
                           to content: UNMutableNotificationContent,
                           partnerName: String) {
        content.title = partnerName
        content.body = body
        content.userInfo[NotificationCategory.heldBannerKey] = category
    }

    private func quieten(_ content: UNMutableNotificationContent) {
        content.sound = nil
        content.interruptionLevel = .passive
    }

    private func applyStatus(_ status: StatusPayload,
                             to content: UNMutableNotificationContent,
                             partnerName: String,
                             reportedAt: Date?) {
        content.title = partnerName
        // Same rule as every screen: a reported or filtered status shows no words.
        let shown = status.moderated(reportedAt: reportedAt)
        if shown.message != status.message {
            content.body = String(localized: "updated their status")
        } else if shown.message.isEmpty {
            content.body = shown.emoji
        } else {
            content.body = "\(shown.emoji) \(shown.message)"
        }
        // Each update stays individually in Notification Centre as history.
        content.threadIdentifier = "status-updates"
    }

    /// The status record changed but its words didn't: the partner renamed
    /// themselves. The push can't be suppressed, so say what actually happened.
    private func applyRename(_ status: StatusPayload,
                             to content: UNMutableNotificationContent,
                             previousName: String) {
        let fallback = String(localized: "Your partner")
        content.title = ContentFilter.displayName(previousName, fallback: fallback)
        content.body = String(localized: "is now going by \(ContentFilter.displayName(status.displayName, fallback: String(localized: "a new name")))")
        content.threadIdentifier = "status-updates"
    }

    private func apply(_ moment: Moment,
                       to content: UNMutableNotificationContent,
                       partnerName: String) async {
        // `partnerName` covers records written before the sender set a name.
        content.title = moment.displaySenderName(fallback: partnerName)
        content.body = moment.displayCaption ?? moment.arrivalSummary

        // The media may not be on disk yet (another process's download may be
        // in flight or failed), so fetch it here rather than settling for text.
        var attachment = MomentAttachment.make(for: moment, suffix: "push")
        if attachment == nil {
            try? await CloudSync.shared.fetchMedia(for: moment)
            attachment = MomentAttachment.make(for: moment, suffix: "push")
        }
        if let attachment {
            content.attachments = [attachment]
        }
    }

    /// The watermark was already advanced by the claim above, under the lock.
    /// Same wording rules as `NotificationManager.postNudge`.
    private func applyNudge(to content: UNMutableNotificationContent,
                            partnerName: String,
                            interruption: AnnouncementPolicy.NudgeInterruption) {
        content.title = partnerName
        content.body = interruption.stale
            ? String(localized: "was thinking of you earlier 💭")
            : String(localized: "is thinking of you 💭")
        content.interruptionLevel = interruption.breaksThroughFocus ? .timeSensitive : .active
    }
}
