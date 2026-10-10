import Foundation
import os
import UserNotifications
import WidgetKit

// Home's notifications-off card and the Lock Screen widget tip.
extension AppModel {
    // MARK: - Notifications off

    /// Re-read on every foregrounding: the fix happens in the Settings app.
    func checkNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let current = NotificationsNotice.current(authorization: settings.authorizationStatus,
                                                  banners: settings.alertStyle,
                                                  lockScreen: settings.lockScreenSetting,
                                                  notificationCenter: settings.notificationCenterSetting,
                                                  timeSensitive: settings.timeSensitiveSetting)
        let (shown, dismissed) = NotificationsNotice.reconcile(current: current,
                                                               dismissed: store.notificationsNoticeDismissed)
        if store.notificationsNoticeDismissed != dismissed { store.notificationsNoticeDismissed = dismissed }
        if notificationsNotice != shown { notificationsNotice = shown }
    }

    func dismissNotificationsNotice() {
        store.notificationsNoticeDismissed = notificationsNotice
        notificationsNotice = nil
    }

    // MARK: - Lock-screen widget tip

    var showsWidgetTip: Bool { isPaired && snapshot.theirs != nil && !widgetTipDismissed }

    func dismissWidgetTip() {
        persist(true, \.widgetTipDismissed, \.widgetTipDismissed)
    }

    /// A Lock Screen widget already in place retires the tip for good; a Home
    /// Screen one doesn't — the tip is about the Lock Screen.
    func checkInstalledWidgets() async {
        guard !widgetTipDismissed else { return }
        // The async form is iOS 18+.
        let onLockScreen = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let accessory: Set<WidgetFamily> = [.accessoryCircular, .accessoryRectangular, .accessoryInline]
                continuation.resume(returning: (try? result.get())?.contains { accessory.contains($0.family) } ?? false)
            }
        }
        if onLockScreen { dismissWidgetTip() }
    }
}
