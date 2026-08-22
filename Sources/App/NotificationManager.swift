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
