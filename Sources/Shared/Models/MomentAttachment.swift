import Foundation
import UserNotifications
import os

/// Turns a moment's media file into a notification attachment. Shared so the
/// app and the notification service extension attach the same thing.
enum MomentAttachment {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "MomentAttachment")

    /// `suffix` only keeps the two call sites from fighting over one temp file
    /// name when a push and a local notification land together.
    static func make(for moment: Moment, suffix: String) -> UNNotificationAttachment? {
        guard let url = MomentStore.shared.temporaryAttachmentCopy(for: moment, suffix: suffix) else {
            return nil
        }
        do {
            // Thumbnail becomes the preview; an `.m4a` becomes a playable clip.
            return try UNNotificationAttachment(identifier: moment.id, url: url)
        } catch {
            log.error("Couldn't attach \(moment.id): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}

/// The banner announcing a partner moment: the app's, and the notification
/// service's for a moment a heart or status push carried. One identifier per
/// moment, so the two never stack copies of it.
enum MomentBanner {
    static func identifier(for momentID: String) -> String { "moment-\(momentID)" }

    /// Worded and stamped, with the default sound; the caller caps it
    /// (`limit(to:)`) last and attaches the picture if it has one.
    static func content(for moment: Moment, from name: String,
                        filterEnabled: Bool = SharedStore.shared.contentFilterEnabled) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = moment.displaySenderName(fallback: name, filterEnabled: filterEnabled)
        content.body = moment.displayCaption(filterEnabled: filterEnabled) ?? moment.arrivalSummary
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.moment
        content.userInfo[BannerSubject.key] = BannerSubject.moment(moment.id).stamp
        return content
    }
}
