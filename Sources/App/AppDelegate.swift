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

    /// Silent push from the CloudKit database subscription.
    ///
    /// The completion-handler form rather than the `async` one on purpose:
    /// `userInfo` isn't `Sendable`, so it is consumed here, synchronously,
    /// instead of being carried across a concurrency boundary.
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
        [.banner, .sound]
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

    /// Hands the invite to the UI rather than accepting it here.
    ///
    /// The join needs a display name, and on a fresh install — by far the
    /// common case for the person being invited — there isn't one yet. This
    /// used to fall back to `UIDevice.current.name`, so people joined as
    /// "Edwin's iPhone". `WelcomeView` asks first, then calls
    /// `AppModel.acceptInvite(name:)`.
    private func accept(_ metadata: CKShare.Metadata) {
        log.notice("Invite link opened; waiting on a name before joining.")
        Task { @MainActor in
            // Both the box and the notification, because the two arrival paths
            // have opposite timing: a cold launch delivers the share *before*
            // any SwiftUI view exists to hear a notification, so `onLaunch`
            // drains the box instead.
            InviteInbox.shared.metadata = metadata
            NotificationCenter.default.post(name: .inviteDidArrive, object: metadata)
        }
    }
}

/// Holds an invite between the scene delegate and the first view that can act
/// on it. Not in `SharedStore`: `CKShare.Metadata` isn't `Codable`, and an
/// invite that doesn't survive a relaunch is fine — the link still works.
@MainActor
final class InviteInbox {
    static let shared = InviteInbox()
    var metadata: CKShare.Metadata?

    func take() -> CKShare.Metadata? {
        defer { metadata = nil }
        return metadata
    }
}

extension Notification.Name {
    static let pairingDidChange = Notification.Name("TetherPairingDidChange")
    static let pairingDidFail = Notification.Name("TetherPairingDidFail")
    /// Object is the `CKShare.Metadata` from the tapped link.
    static let inviteDidArrive = Notification.Name("TetherInviteDidArrive")
}
