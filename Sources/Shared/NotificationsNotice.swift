import UserNotifications

/// Home's notice that alerts won't reach this person — alerts are the product.
/// Pure, so the arming rule is tested; `AppModel` reads the system settings.
enum NotificationsNotice: String, Equatable, Sendable {
    /// Denied outright.
    case off
    /// Allowed, but every way of showing one is off — no banner, Lock Screen or
    /// Notification Center: hearts arrive and nobody sees them.
    case bannersOff
    /// Time Sensitive is off, so a heart waits out a Focus.
    case focusBlocked

    /// `notDetermined` shows nothing: the prompt is still to come (pairing asks).
    static func current(authorization: UNAuthorizationStatus,
                        banners: UNAlertStyle,
                        lockScreen: UNNotificationSetting,
                        notificationCenter: UNNotificationSetting,
                        timeSensitive: UNNotificationSetting) -> NotificationsNotice? {
        switch authorization {
        case .denied: return .off
        case .authorized, .provisional, .ephemeral: break
        default: return nil
        }
        // Any one still showing them is a working setup, just a quieter one.
        if banners == .none, lockScreen != .enabled, notificationCenter != .enabled { return .bannersOff }
        if timeSensitive == .disabled { return .focusBlocked }
        return nil
    }

    /// A dismissal holds only while that same problem stands: once it changes
    /// (fixed, or a different one) it's forgotten, so switching notifications
    /// off again brings the notice back.
    static func reconcile(current: NotificationsNotice?,
                          dismissed: NotificationsNotice?) -> (shown: NotificationsNotice?, dismissed: NotificationsNotice?) {
        guard let current else { return (nil, nil) }
        return current == dismissed ? (nil, dismissed) : (current, nil)
    }
}
