import CloudKit
import UIKit
import UserNotifications
import os

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
        // Required for CloudKit database subscriptions to reach us at all.
        application.registerForRemoteNotifications()
        return true
    }

    /// SwiftUI's `App` lifecycle has no scene delegate of its own, but accepted
    /// CloudKit shares are only delivered to one — so we attach ours here.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil,
                                                 sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on the Simulator without a paid team; sync then falls back
        // to foreground refresh and the widget's own periodic fetch.
        log.error("Remote notification registration failed: \(error.localizedDescription)")
    }

    /// Background CloudKit push — in practice only the pre-1.1 silent subscription,
    /// kept so those devices keep refreshing until `registerSubscription` deletes it.
    /// Completion-handler form on purpose: `userInfo` isn't `Sendable`, so consume it synchronously.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let changed = await SyncRunner.refreshQuietly()
            completionHandler(changed ? .newData : .noData)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Nudges are the whole point, so show them even with the app open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The only signal the open app gets that something arrived (all pushes are
        // visible now). The service extension already refreshed the store — tell the
        // model to re-read it, or the home screen lags the banner on top of it.
        await MainActor.run {
            NotificationCenter.default.post(name: .pairingDidChange, object: nil)
        }
        return [.banner, .sound]
    }

    /// Banner actions. The app may be launched into the background for these,
    /// so the work goes through the model (created in `RedStringApp.init`, ahead
    /// of any delegate callback) and is awaited — returning early would suspend
    /// the process mid-publish.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        switch action {
        case NotificationCategory.Action.heartBack:
            await AppModel.current?.sendNudge()
        case NotificationCategory.Action.replyStatus:
            let message = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !message.isEmpty else { return }
            await AppModel.current?.setStatus(emoji: "💬", message: message)
        default:
            break
        }
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "SceneDelegate")

    /// Cold launch straight from tapping the invite link.
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata)
        }
    }

    /// App already running when the link is tapped.
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(cloudKitShareMetadata)
    }

    /// Hands the invite to the UI rather than accepting here: the join needs a
    /// display name, and `WelcomeView` asks first, then calls `AppModel.acceptInvite(name:)`.
    private func accept(_ metadata: CKShare.Metadata) {
        log.notice("Invite link opened; waiting on a name before joining.")
        Task { @MainActor in
            // Both the box and the notification: a cold launch delivers the share before
            // any view can hear a notification, so `onLaunch` drains the box instead.
            InviteInbox.shared.metadata = metadata
            NotificationCenter.default.post(name: .inviteDidArrive, object: metadata)
        }
    }
}

/// Holds an invite between the scene delegate and the first view that can act on it.
/// Not in `SharedStore`: `CKShare.Metadata` isn't `Codable`, and the link survives a relaunch anyway.
@MainActor
final class InviteInbox {
    static let shared = InviteInbox()
    var metadata: CKShare.Metadata?

    func take() -> CKShare.Metadata? {
        defer { metadata = nil }
        return metadata
    }
}
