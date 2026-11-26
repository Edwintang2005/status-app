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

    // MARK: - The milestone day

    /// Today's milestone, for Home's card — until waved away. Both phones, unlike
    /// the opt-in reminders: you're here, so it's no interruption.
    func milestoneOnHome(now: Date = Date()) -> HomeNotice.MilestoneDay? {
        guard isPaired, !snapshot.partnerHasLeft, let anniversary = snapshot.anniversary,
              let today = anniversary.milestoneToday(now) else { return nil }
        let key = today.dayKey(of: anniversary)
        return key == milestoneNoticeDismissed ? nil : HomeNotice.MilestoneDay(title: today.title, key: key)
    }

    func dismissMilestoneNotice(_ day: HomeNotice.MilestoneDay) {
        persist(day.key, \.milestoneNoticeDismissed, \.milestoneNoticeDismissed)
    }

    /// `true` the first time this milestone shows on this iPhone: its hearts rise once.
    func claimMilestoneCelebration(_ day: HomeNotice.MilestoneDay) -> Bool {
        let key = day.key
        guard store.milestoneCelebrated != key else { return false }
        store.milestoneCelebrated = key
        return true
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
