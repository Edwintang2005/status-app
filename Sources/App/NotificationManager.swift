import Foundation
import UserNotifications
import os

/// Local notifications for events the app itself notices — a refresh that
/// turns up a nudge or moment nobody has been told about. The *usual*
/// announcement path is the visible CloudKit push enriched by the service
/// extension; these fire when that path was missed (a dropped push, an
/// extension refresh that failed) and the app finds the event first.
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
    /// Removes delivered banners still wearing CloudKit's generic wording —
    /// the ones a failed service-extension refresh couldn't enrich. The local
    /// notification about to be posted says the same thing properly, and
    /// leaving both is a duplicate.
    ///
    /// Matched on the *body*, not just the app-name title: only the wording
    /// this local notification supersedes may go. Sweeping every generic
    /// banner deleted unenriched status notes that nothing was ever going to
    /// re-state.
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

    /// `sentAt` is when the nudge actually happened (`StatusPayload.lastNudgeAt`).
    /// This path only runs when the real-time push was missed, which can be
    /// seconds ago (dropped push) or hours ago (extension failed, app closed
    /// since) — and the wording must not claim a stale nudge is happening
    /// now: announced during whatever refresh finally noticed it, "is thinking
    /// of you" reads as mislabelling the event that triggered the refresh.
    static func postNudge(from name: String, sentAt: Date?) async {
        await removeGenericBanners(body: CloudSync.GenericAlert.nudge)
        let stale = sentAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? false

        let content = UNMutableNotificationContent()
        content.title = name
        content.body = stale ? "was thinking of you earlier 💭" : "is thinking of you 💭"
        content.sound = .default
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
