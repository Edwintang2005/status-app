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

        // What this device knew before the refresh — a status push whose emoji
        // and message match it is a rename, and is worded as one.
        let previousStatus = await MainActor.run { SharedStore.shared.snapshot.theirs }

        let result: RefreshResult
        do {
            result = try await CloudSync.shared.refresh()
        } catch {
            log.error("Refresh failed in service extension: \(error.localizedDescription)")
            return content
        }

        let partnerName = await MainActor.run { SharedStore.shared.snapshot.partnerDisplayName }

        // Dispatch by subscriptionID, never by the sync delta: whichever
        // process refreshes first consumes the delta, so it can't classify the push.
        switch notification.subscriptionID {
        case CloudSync.SubscriptionID.moment?:
            // Prefer the newest *un-announced* moment — from this refresh's delta
            // first, then the index — picked and claimed inside one `mutate` under
            // the cross-process lock: rapid-fire pushes run as concurrent extension
            // instances and must not claim (or re-caption) the same moment.
            let fromDelta = result.newPartnerMoments.sorted { $0.sentAt > $1.sentAt }
            let fromIndex = MomentIndex.shared.load().filter { !$0.fromMe }
            let moment = await MainActor.run { () -> Moment? in
                var chosen: Moment?
                _ = SharedStore.shared.mutate(reloadWidgets: false) { snapshot in
                    chosen = fromDelta.first { !snapshot.hasAnnounced($0.id) }
                        ?? fromIndex.first { !snapshot.hasAnnounced($0.id) }
                        ?? fromDelta.first
                        ?? fromIndex.first
                    if let chosen { snapshot.recordAnnounced(chosen.id) }
                }
                return chosen
            }
            if let moment {
                await apply(moment, to: content, partnerName: partnerName)
            }
        case CloudSync.SubscriptionID.nudge?:
            var count = result.partnerStatus?.nudgeCount
            if count == nil {
                count = await MainActor.run { SharedStore.shared.snapshot.theirs?.nudgeCount }
            }
            if let count {
                await applyNudge(to: content, partnerName: partnerName, nudgeCount: count)
            }
        case CloudSync.SubscriptionID.status?:
            // Rewrite judged by watermark, not by "did *my* refresh see the
            // change" — the widget often consumes the delta first. Check-and-claim
            // in one `mutate` under the cross-process lock so concurrent pushes
            // don't both rewrite.
            if let status = result.partnerStatus {
                let claimed = await MainActor.run { () -> Bool in
                    var claimed = false
                    _ = SharedStore.shared.mutate(reloadWidgets: false) {
                        let announced = $0.lastAnnouncedPartnerStatusAt ?? .distantPast
                        guard status.updatedAt > announced else { return }
                        $0.lastAnnouncedPartnerStatusAt = status.updatedAt
                        claimed = true
                    }
                    return claimed
                }
                if claimed {
                    if let previousStatus, previousStatus.emoji == status.emoji,
                       previousStatus.message == status.message,
                       previousStatus.displayName != status.displayName {
                        applyRename(status, to: content, previousName: previousStatus.displayName)
                    } else {
                        applyStatus(status, to: content, partnerName: partnerName)
                    }
                }
            }
        default:
            // Legacy silent push or unknown subscription — the refresh already ran.
            break
        }

        return content
    }

    private func applyStatus(_ status: StatusPayload,
                             to content: UNMutableNotificationContent,
                             partnerName: String) {
        content.title = partnerName
        content.body = status.message.isEmpty
            ? status.emoji
            : "\(status.emoji) \(status.message)"
        // Each update stays individually in Notification Centre as history.
        content.threadIdentifier = "status-updates"
    }

    /// The status record changed but its words didn't: the partner renamed
    /// themselves. The push can't be suppressed, so say what actually happened.
    private func applyRename(_ status: StatusPayload,
                             to content: UNMutableNotificationContent,
                             previousName: String) {
        let old = previousName.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = old.isEmpty ? String(localized: "Your partner") : old
        content.body = String(localized: "is now going by \(status.displayName)")
        content.threadIdentifier = "status-updates"
    }

    private func apply(_ moment: Moment,
                       to content: UNMutableNotificationContent,
                       partnerName: String) async {
        // `partnerName` covers records written before the sender set a name.
        content.title = moment.senderName.isEmpty ? partnerName : moment.senderName
        content.body = moment.caption.isEmpty ? moment.arrivalSummary : moment.caption

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

    private func applyNudge(to content: UNMutableNotificationContent,
                            partnerName: String,
                            nudgeCount: Int) async {
        content.title = partnerName
        content.body = String(localized: "is thinking of you 💭")
        content.interruptionLevel = .timeSensitive

        // Awaited — the process may suspend once the handler runs. `max`, not
        // assignment: concurrent instances can land writes out of order, and a
        // watermark moved backwards means a duplicate announcement later.
        await MainActor.run {
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                $0.lastSeenPartnerNudgeCount = max($0.lastSeenPartnerNudgeCount, nudgeCount)
            }
        }
    }
}
