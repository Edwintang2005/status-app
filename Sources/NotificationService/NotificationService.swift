import CloudKit
import UserNotifications
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Runs when CloudKit delivers a nudge or moment push.
///
/// This is what makes those notifications survive a force-quit. CloudKit sends
/// them as *visible* alerts — APNs displays them whether or not the app is
/// running — and `shouldSendMutableContent` hands them here first, for about
/// thirty seconds, before the user sees anything.
///
/// That window is used to do the work the app would otherwise have to be alive
/// for: fetch the change, **decrypt it on-device**, write it into the App Group,
/// reload the widget, attach the photo or recording, and replace CloudKit's
/// deliberately generic wording with the real caption and name. None of that is
/// possible server-side, because CloudKit cannot read the encrypted fields.
final class NotificationService: UNNotificationServiceExtension {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "NotificationService")

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        self.fallback = mutable

        work = Task { [weak self] in
            guard let self else { return }
            let enriched = await self.enrich(mutable, userInfo: request.content.userInfo)
            contentHandler(enriched ?? request.content)
        }
    }

    /// Out of time — show CloudKit's generic version rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        // The refresh may have landed its records before the deadline hit;
        // without this the widget misses exactly the pushes that ran long.
        SharedStore.reloadWidgets()
        if let fallback {
            contentHandler?(fallback)
        }
    }

    // MARK: - Enrichment

    private func enrich(_ content: UNMutableNotificationContent?,
                        userInfo: [AnyHashable: Any]) async -> UNNotificationContent? {
        guard let content else { return nil }
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return content
        }

        // The widget is the whole point of doing this here: on a force-quit
        // phone nothing else will update it until the user opens the app.
        // Deferred so it runs on *every* exit — a refresh that throws midway
        // may still have applied records (apply happens before the token is
        // persisted), and skipping the reload then is how a status banner
        // arrives while the lock-screen widget keeps yesterday's status.
        defer { SharedStore.reloadWidgets() }

        let result: RefreshResult
        do {
            result = try await CloudSync.shared.refresh()
        } catch {
            log.error("Refresh failed in service extension: \(error.localizedDescription)")
            return content
        }

        let partnerName = await MainActor.run { SharedStore.shared.snapshot.partnerDisplayName }

        // The push itself says what it is — the sync delta doesn't. Whichever
        // process refreshes first consumes the delta, so "no new moment in
        // *my* refresh" proves nothing about the push: classifying by delta
        // rewrote moment pushes as nudges (and vice versa) whenever a heart
        // and a photo arrived close together.
        switch notification.subscriptionID {
        case CloudSync.SubscriptionID.moment?:
            // The delta's moment when this refresh got it; otherwise the
            // index — whoever consumed the delta recorded it there. Prefer
            // the newest *un-announced* one (`Snapshot.notifiedMomentIDs`):
            // several moments sent seconds apart are several pushes, and
            // whichever process consumed the delta has already claimed the
            // newest — labelling every banner with its caption left the
            // older moments' captions never shown.
            //
            // Picked and claimed inside one `mutate`, under the cross-process
            // lock: those rapid-fire pushes run as *concurrent* extension
            // instances, and a pick outside the lock let two of them choose
            // the same un-announced moment — the newest caption on both
            // banners, the older one never shown. Claiming before the media
            // work is safe because the banner is guaranteed to display this
            // content object even on expiry, title and body already set.
            let fromIndex = MomentIndex.shared.load().filter { !$0.fromMe }
            let moment = await MainActor.run { () -> Moment? in
                var chosen: Moment?
                _ = SharedStore.shared.mutate(reloadWidgets: false) { snapshot in
                    chosen = result.newestPartnerMoment
                        ?? fromIndex.first { !snapshot.hasAnnounced($0.id) }
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
            // Rewrite whenever the partner has a status this device hasn't
            // announced yet, judged by watermark rather than by "did *my*
            // refresh see the change": the widget shares the change token and
            // its own refresh often consumes the delta first, which made this
            // push's delta empty and left the generic wording standing —
            // exactly when the app was closed. A push fired by *this user's
            // own other device* still shows the generic text: it doesn't move
            // the partner's `updatedAt`, so the watermark check fails.
            // Check-and-claim inside one `mutate`, under the cross-process
            // lock, so two near-simultaneous pushes don't both rewrite.
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
                    applyStatus(status, to: content, partnerName: partnerName)
                }
            }
        default:
            // The legacy silent status push or an unknown future
            // subscription: the refresh above already did the useful work.
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
        // Every status update stays in Notification Centre individually —
        // collapsing them into one would defeat the point of having the
        // history to scroll back through.
        content.threadIdentifier = "status-updates"
    }

    private func apply(_ moment: Moment,
                       to content: UNMutableNotificationContent,
                       partnerName: String) async {
        // The moment carries the sender's own name; `partnerName` is a
        // fallback for records written before they'd set one.
        content.title = moment.senderName.isEmpty ? partnerName : moment.senderName
        content.body = moment.caption.isEmpty ? moment.arrivalSummary : moment.caption

        // The media may not be on disk yet: this moment can come from the
        // index fallback — another process consumed the delta, and its media
        // download may have failed or still be in flight — and even this
        // refresh's own `downloadRecentMedia` is best-effort. A banner without
        // the picture defeats the point of the attachment, so fetch it here
        // rather than settling for text.
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
        content.body = "is thinking of you 💭"
        content.interruptionLevel = .timeSensitive

        // Awaited: the system may suspend this process the instant the
        // content handler runs, and a fire-and-forget write that never lands
        // means the app re-announces the same nudge on its next refresh.
        // `max`, not assignment: two taps in quick succession run as
        // concurrent extension instances, and the one carrying the older
        // count can land its write second — a watermark moved backwards is a
        // duplicate "thinking of you" on the app's next refresh.
        await MainActor.run {
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                $0.lastSeenPartnerNudgeCount = max($0.lastSeenPartnerNudgeCount, nudgeCount)
            }
        }
    }
}
