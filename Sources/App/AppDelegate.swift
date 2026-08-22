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

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            let name = SharedStore.shared.snapshot.mine?.displayName ?? UIDevice.current.name
            do {
                try await CloudSync.shared.acceptShare(metadata, displayName: name)
                NotificationCenter.default.post(name: .pairingDidChange, object: nil)
            } catch {
                log.error("Failed to accept share: \(error.localizedDescription)")
                NotificationCenter.default.post(name: .pairingDidFail,
                                                object: error.localizedDescription)
            }
        }
    }
}

extension Notification.Name {
    static let pairingDidChange = Notification.Name("TetherPairingDidChange")
    static let pairingDidFail = Notification.Name("TetherPairingDidFail")
}
