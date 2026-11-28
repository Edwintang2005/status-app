import AppIntents
import UIKit

/// What `AppModel` asks of the running app, injected: a unit test has no app
/// (`UIApplication.shared` isn't there to ask), so it passes `.detached`.
struct AppEnvironment: Sendable {
    var isInFront: @MainActor @Sendable () -> Bool
    var keepScreenAwake: @MainActor @Sendable (Bool) -> Void
    /// `false` to the completion when nothing could open it (no Mail account).
    var openURL: @MainActor @Sendable (URL, @escaping @MainActor @Sendable (Bool) -> Void) -> Void
    var beginBackgroundTask: @MainActor @Sendable (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    var endBackgroundTask: @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void
    /// Pending local notifications (`NotificationManager`): the notification centre needs an app too.
    var scheduleMilestoneReminders: @Sendable ([MilestoneReminderPlan.Reminder]) async -> Void
    var scheduleRecapReminder: @Sendable (RecapPlan.Reminder?) async -> Void
    var requestNotificationAuthorization: @Sendable () async -> Void
    /// Tells iOS a status was set here, so Siri Suggestions and Spotlight learn
    /// when you tend to set it (`SetStatusIntent`); `nil` forgets them all.
    var donateStatus: @Sendable (StatusOption?) async -> Void

    @MainActor static let live = AppEnvironment(
        isInFront: { UIApplication.shared.applicationState == .active },
        keepScreenAwake: { UIApplication.shared.isIdleTimerDisabled = $0 },
        openURL: { url, done in UIApplication.shared.open(url) { opened in done(opened) } },
        beginBackgroundTask: { name, expired in
            UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expired() } }
        },
        endBackgroundTask: { UIApplication.shared.endBackgroundTask($0) },
        scheduleMilestoneReminders: { await NotificationManager.scheduleMilestoneReminders($0) },
        scheduleRecapReminder: { await NotificationManager.scheduleRecapReminder($0) },
        requestNotificationAuthorization: { await NotificationManager.requestAuthorizationIfNeeded() },
        donateStatus: { status in
            guard let status else {
                _ = try? await IntentDonationManager.shared.deleteDonations(matching: .intentType(SetStatusIntent.self))
                return
            }
            var intent = SetStatusIntent()
            intent.status = status
            _ = try? await IntentDonationManager.shared.donate(intent: intent)
        })

    /// In front, nothing to keep awake, open or schedule, no background time to claim.
    static let detached = AppEnvironment(
        isInFront: { true },
        keepScreenAwake: { _ in },
        openURL: { _, done in done(false) },
        beginBackgroundTask: { _, _ in .invalid },
        endBackgroundTask: { _ in },
        scheduleMilestoneReminders: { _ in },
        scheduleRecapReminder: { _ in },
        requestNotificationAuthorization: {},
        donateStatus: { _ in })
}
