import Foundation
import UserNotifications
import os

/// Turns a moment's media file into a notification attachment.
///
/// Shared because both the app and the notification service extension attach
/// the same thing, and the wording and the attachment have to agree between
/// them — the extension enriches a push the app would otherwise have raised
/// itself.
enum MomentAttachment {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "MomentAttachment")

    /// `suffix` only keeps the two call sites from fighting over one temp file
    /// name when a push and a local notification land together.
    static func make(for moment: Moment, suffix: String) -> UNNotificationAttachment? {
        guard let url = MomentStore.shared.temporaryAttachmentCopy(for: moment, suffix: suffix) else {
            return nil
        }
        do {
            // The image thumbnail becomes the preview; an `.m4a` becomes a
            // playable clip inside the expanded notification.
            return try UNNotificationAttachment(identifier: moment.id, url: url)
        } catch {
            log.error("Couldn't attach \(moment.id): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
