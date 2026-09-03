import Foundation
import UserNotifications
import os

/// Local notifications for events the app itself notices. The usual path is the
/// visible CloudKit push; these fire only when that was missed and a refresh finds the event first.
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

    /// Actions on the banners: a heart back on all three, a text reply on a
    /// status. Handled in `AppDelegate.userNotificationCenter(_:didReceive:)`.
    static func registerCategories() {
        let heart = UNNotificationAction(
            identifier: NotificationCategory.Action.heartBack,
            title: String(localized: "Send a heart back"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "heart.fill"))
        let reply = UNTextInputNotificationAction(
            identifier: NotificationCategory.Action.replyStatus,
            title: String(localized: "Reply with a status"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "text.bubble"),
            textInputButtonTitle: String(localized: "Set"),
            textInputPlaceholder: String(localized: "Say anything"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: NotificationCategory.status,
                                   actions: [heart, reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategory.nudge,
                                   actions: [heart], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategory.moment,
                                   actions: [heart], intentIdentifiers: []),
        ])
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Sweeps this app's delivered notifications. Called on active and on inactive —
    /// iOS has no "Notification Centre opened" signal, and the inactive transition
    /// (the shade pulled over the open app) is the closest proxy.
    static func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Removes delivered banners still wearing CloudKit's generic wording — the local
    /// notification about to be posted supersedes them, and leaving both is a duplicate.
    /// Matched on the *body*, not just the app-name title: sweeping every generic
    /// banner deleted unenriched status notes nothing was ever going to re-state.
    private static func removeGenericBanners(body: String) async {
        let center = UNUserNotificationCenter.current()
        let generic = await center.deliveredNotifications()
            .filter {
                $0.request.content.title == AppConfig.appName
                    && $0.request.content.body == body
            }
            .map(\.request.identifier)
        guard !generic.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: generic)
    }

    static func postMoment(_ moment: Moment, from name: String) async {
        await removeGenericBanners(body: CloudSync.GenericAlert.moment)
        let content = UNMutableNotificationContent()
        content.title = moment.senderName.isEmpty ? name : moment.senderName
        content.body = moment.caption.isEmpty ? moment.arrivalSummary : moment.caption
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.moment

        // If the refresh's best-effort media download failed, fetch here rather
        // than announcing a photo with no photo.
        var attachment = MomentAttachment.make(for: moment, suffix: "notify")
        if attachment == nil {
            try? await Backend.current.fetchMedia(for: moment)
            attachment = MomentAttachment.make(for: moment, suffix: "notify")
        }
        if let attachment {
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

    /// `sentAt` is when the nudge actually happened. This path can run hours late,
    /// and the wording must not claim a stale nudge is happening now.
    static func postNudge(from name: String, sentAt: Date?) async {
        await removeGenericBanners(body: CloudSync.GenericAlert.nudge)
        let stale = sentAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? false

        let content = UNMutableNotificationContent()
        content.title = name
        content.body = stale
            ? String(localized: "was thinking of you earlier 💭")
            : String(localized: "is thinking of you 💭")
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.nudge
        // Old news doesn't get to break through Focus the way a live tap does.
        if !stale { content.interruptionLevel = .timeSensitive }

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
