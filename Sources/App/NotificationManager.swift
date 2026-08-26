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

    /// Sweeps this app's delivered notifications out of Notification Centre.
    ///
    /// Called when the app is open (everything a banner announced is on
    /// screen) and when the scene goes inactive — which is what happens when
    /// Notification Centre is pulled down *over* the open app, so the sweep
    /// lands exactly as the user looks. iOS offers no "Notification Centre
    /// opened" signal; the inactive transition is the closest proxy, and the
    /// other things that trigger it (App Switcher, Control Centre, a call
    /// banner) all mean the user just had the app's live state in front of
    /// them anyway.
    static func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// A photo, drawing or voice memo arrived. The file rides along as an
    /// attachment, which for an image means it's visible from the lock screen
    /// and for a memo means it can be played from the expanded notification —
    /// either way without opening the app.
    /// `name` is only a fallback: the moment carries the name its sender had
    /// when they sent it, and that's what should appear.
    static func postMoment(_ moment: Moment, from name: String) async {
        let content = UNMutableNotificationContent()
        content.title = moment.senderName.isEmpty ? name : moment.senderName
        content.body = moment.caption.isEmpty ? moment.arrivalSummary : moment.caption
        content.sound = .default

        if let attachment = MomentAttachment.make(for: moment, suffix: "notify") {
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
