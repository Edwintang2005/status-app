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
/// reload the widget, and replace CloudKit's deliberately generic wording with
/// the real caption and name. None of that is possible server-side, because
/// CloudKit cannot read the encrypted fields.
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
        if let fallback {
            contentHandler?(fallback)
        }
    }

    // MARK: - Enrichment

    private func enrich(_ content: UNMutableNotificationContent?,
                        userInfo: [AnyHashable: Any]) async -> UNNotificationContent? {
        guard let content else { return nil }
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            return content
        }

        let result: RefreshResult
        do {
            result = try await CloudSync.shared.refresh()
        } catch {
            log.error("Refresh failed in service extension: \(error.localizedDescription)")
            return content
        }

        // The widget is the whole point of doing this here: on a force-quit
        // phone nothing else will update it until the user opens the app.
        SharedStore.reloadWidgets()

        let partnerName = await MainActor.run { SharedStore.shared.snapshot.partnerDisplayName }

        if let moment = result.newestPartnerMoment {
            await apply(moment, to: content, partnerName: partnerName)
        } else if let status = result.partnerStatus {
            applyNudge(to: content, partnerName: partnerName, nudgeCount: status.nudgeCount)
        }

        return content
    }

    private func apply(_ moment: Moment,
                       to content: UNMutableNotificationContent,
                       partnerName: String) async {
        // The moment carries the sender's own name; `partnerName` is a
        // fallback for records written before they'd set one.
        content.title = moment.senderName.isEmpty ? partnerName : moment.senderName
        content.body = moment.caption.isEmpty
            ? (moment.kind == .photo ? "sent you a photo 📷" : "sent you a drawing ✏️")
            : moment.caption

        if let attachment = Self.attachment(for: moment) {
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
                            nudgeCount: Int) {
        content.title = partnerName
        content.body = "is thinking of you 💭"
        content.interruptionLevel = .timeSensitive

        Task { @MainActor in
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                $0.lastSeenPartnerNudgeCount = nudgeCount
            }
        }
    }

    /// `UNNotificationAttachment` takes ownership of the file it's handed, so
    /// give it a throwaway copy rather than the App Group original.
    private static func attachment(for moment: Moment) -> UNNotificationAttachment? {
        guard let source = MomentStore.shared.thumbURL(for: moment.id),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(moment.id)-push.jpg")
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: source, to: temp)
            return try UNNotificationAttachment(identifier: moment.id, url: temp)
        } catch {
            return nil
        }
    }
}
