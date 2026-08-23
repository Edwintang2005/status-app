import Foundation
import UserNotifications
import os

/// CloudKit database subscriptions can only deliver *silent* pushes, so the
/// user-visible alert for a nudge is a local notification raised by this app
/// once the silent push has woken it and the fetch has come back.
@MainActor
enum NotificationManager {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "Notifications")

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            SharedStore.shared.hasRequestedNotifications = true
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// A photo or drawing arrived. The image rides along as an attachment so
    /// it's visible from the lock screen without opening the app.
    static func postMoment(_ moment: Moment, from name: String) async {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = moment.caption.isEmpty
            ? (moment.kind == .photo ? "sent you a photo 📷" : "sent you a drawing ✏️")
            : moment.caption
        content.sound = .default

        if let attachment = attachment(for: moment) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: "moment-\(moment.id)",
                                            content: content,
                                            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("Failed to post moment notification: \(error.localizedDescription)")
        }
    }

    /// UNNotificationAttachment takes ownership of the file it's handed, so
    /// give it a throwaway copy rather than the App Group original.
    private static func attachment(for moment: Moment) -> UNNotificationAttachment? {
        guard let source = MomentStore.shared.thumbURL(for: moment.id),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(moment.id)-notify.jpg")
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: source, to: temp)
            return try UNNotificationAttachment(identifier: moment.id, url: temp)
        } catch {
            log.error("Couldn't attach moment image: \(error.localizedDescription)")
            return nil
        }
    }

    static func postNudge(from name: String) async {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "is thinking of you 💭"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: "nudge-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("Failed to post nudge notification: \(error.localizedDescription)")
        }
    }
}
