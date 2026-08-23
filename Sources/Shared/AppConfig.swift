import Foundation

/// Every identifier that has to stay in lockstep with the entitlements files
/// and `project.yml`. Change these four strings together when rebranding.
enum AppConfig {
    static let appName = "Tether"

    /// Must match `com.apple.security.application-groups` in both entitlements files.
    static let appGroupID = "group.com.edwintang.tether"

    /// Must match `com.apple.developer.icloud-container-identifiers` in both
    /// entitlements files.
    static let cloudContainerID = "iCloud.com.edwintang.tether"

    /// Custom zone holding both partners' status records. Custom (not default)
    /// zones are required for both zone sharing and database subscriptions.
    static let coupleZoneName = "CoupleZone"

    /// Identifier passed to `WidgetCenter` reloads and declared by the widget.
    static let widgetKind = "TetherStatusWidget"

    /// Minimum gap between nudges, so a stuck thumb can't spam the other phone.
    static let nudgeCooldown: TimeInterval = 60

    /// Identifier for the photo/drawing widget.
    static let momentWidgetKind = "TetherMomentWidget"

    /// How many moments each device keeps locally. The server only ever holds
    /// the latest one per person; history is accumulated on-device.
    static let momentHistoryLimit = 30
}
