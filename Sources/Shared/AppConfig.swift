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

    /// Minimum gap between nudges. Short on purpose: this exists to stop a
    /// double-tap sending twice while the first write is still in flight, not
    /// to ration affection. Sending a few hearts in a row is the point.
    static let nudgeCooldown: TimeInterval = 3

    /// Identifier for the photo/drawing widget.
    static let momentWidgetKind = "TetherMomentWidget"

    /// Entries kept in the on-device history index. Metadata only, so this can
    /// be generous — CloudKit keeps everything regardless, and a fresh install
    /// pulls the whole zone back.
    static let momentHistoryLimit = 500

    /// How many recent moments keep their image files on this device. Older
    /// ones are fetched from CloudKit on demand when you scroll to them.
    static let momentImageCacheLimit = 60
}
