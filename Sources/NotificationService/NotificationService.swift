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

        // Captured before the refresh, so a status push can tell "the partner
        // said something new" apart from "this user's own other device wrote,
        // and the partner's status is merely still there".
        let partnerStatusBefore = await MainActor.run { SharedStore.shared.snapshot.theirs }

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
            // index — whoever consumed the delta recorded it there.
            let moment = result.newestPartnerMoment
                ?? MomentIndex.shared.load().first { !$0.fromMe }
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
            // Rewrite only when the partner's status actually changed in this
            // delta. A change made by *this user's own other device* also
            // lands here, and `partnerStatus` falls back to the existing
            // value — rewriting with that would mislabel the banner. The
            // generic text stands for that edge.
            if let status = result.partnerStatus, status != partnerStatusBefore {
                applyStatus(status, to: content, partnerName: partnerName)
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

        if let attachment = MomentAttachment.make(for: moment, suffix: "push") {
            content.attachments = [attachment]
        }

        // Record that the user has now been told, so the app doesn't raise a
        // duplicate local notification the next time it refreshes.
        await MainActor.run {
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                $0.lastNotifiedMomentID = moment.id
            }
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
        await MainActor.run {
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                $0.lastSeenPartnerNudgeCount = nudgeCount
            }
        }
    }
}
