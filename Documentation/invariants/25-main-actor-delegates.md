# Invariant 25: UIKit delegate callbacks with a completion run on the main actor — never nonisolated async

Read before touching `AppDelegate`, any UIKit/UserNotifications delegate.

**UIKit delegate callbacks with a completion run on the main actor — never `nonisolated async`.** The thunk calls the completion wherever the body finishes, and `UNUserNotificationCenterDelegate.didReceive`'s asserts the main thread. `AppDelegate` conforms `@preconcurrency` so its witnesses can be main-actor isolated despite non-`Sendable` `UNNotification`/`UNNotificationResponse`; keep new ones the same.
