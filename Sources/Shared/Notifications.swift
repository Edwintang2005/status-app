import Foundation

/// Notification categories and actions. Shared because the app registers and
/// handles them while the notification service stamps them on rewritten banners.
enum NotificationCategory {
    static let status = "status"
    static let nudge = "nudge"
    static let moment = "moment"

    enum Action {
        /// One-tap heart back, offered on every category.
        static let heartBack = "heart-back"
        /// Text reply on a status banner; the words become this device's status.
        static let replyStatus = "reply-status"
    }
}

extension Notification.Name {
    static let pairingDidChange = Notification.Name("RedStringPairingDidChange")
    static let pairingDidFail = Notification.Name("RedStringPairingDidFail")
    /// Object is the `CKShare.Metadata` from the tapped link.
    static let inviteDidArrive = Notification.Name("RedStringInviteDidArrive")
}
