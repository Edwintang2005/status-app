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
        // Face ID first: from a locked phone, anyone holding it could post as you.
        let reply = UNTextInputNotificationAction(
            identifier: NotificationCategory.Action.replyStatus,
            title: String(localized: "Reply with a status"),
            options: [.authenticationRequired],
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

    /// Sweeps this app's delivered notifications. Called when the app becomes
    /// active — everything a banner said is then on screen.
    static func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Removes delivered banners still wearing CloudKit's generic wording, or the
    /// locked-phone wording the service stamps — the local notification about to
    /// be posted supersedes them, and leaving both is a duplicate. Matched on the
    /// *body* (or stamp), not just the app-name title: sweeping every generic
    /// banner deleted unenriched status notes nothing was ever going to re-state.
    @discardableResult
    private static func removeGenericBanners(body: String, category: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let generic = await center.deliveredNotifications()
            .filter {
                let content = $0.request.content
                return (content.title == AppConfig.appName && content.body == body)
                    || content.userInfo[NotificationCategory.heldBannerKey] as? String == category
            }
            .map(\.request.identifier)
        guard !generic.isEmpty else { return false }
        center.removeDeliveredNotifications(withIdentifiers: generic)
        return true
    }

    static func postMoment(_ moment: Moment, from name: String) async {
        let superseded = await removeGenericBanners(body: CloudSync.GenericAlert.moment,
                                                    category: NotificationCategory.moment)
        let content = UNMutableNotificationContent()
        content.title = moment.displaySenderName(fallback: name)
        content.body = moment.displayCaption ?? moment.arrivalSummary
        // Replacing a banner that already alerted (generic or locked-phone
        // wording): the words get better, the phone doesn't buzz twice.
        if superseded {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        content.categoryIdentifier = NotificationCategory.moment

        // If the refresh's best-effort media download failed, fetch here rather
        // than announcing a photo with no photo. Bounded: this can run inside a
        // background-fetch budget, which iOS ends silently when overrun.
        var attachment = MomentAttachment.make(for: moment, suffix: "notify")
        if attachment == nil {
            try? await withDeadline(AppConfig.widgetDeadline) { try await Backend.current.fetchMedia(for: moment) }
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
        await removeGenericBanners(body: CloudSync.GenericAlert.nudge, category: NotificationCategory.nudge)
        var interruption = AnnouncementPolicy.NudgeInterruption(stale: false, breaksThroughFocus: false)
        _ = SharedStore.shared.mutate(reloadWidgets: false) {
            interruption = AnnouncementPolicy.nudgeInterruption(sentAt: sentAt, in: &$0)
        }

        let content = UNMutableNotificationContent()
        content.title = name
        content.body = interruption.stale
            ? String(localized: "was thinking of you earlier 💭")
            : String(localized: "is thinking of you 💭")
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.nudge
        // Old news, or a repeat within the interval, doesn't get to break through Focus.
        content.interruptionLevel = interruption.breaksThroughFocus ? .timeSensitive : .active

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
