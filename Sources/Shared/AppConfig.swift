import Foundation

/// Every identifier that has to stay in lockstep with the entitlements files
/// and `project.yml`. Change these four strings together when rebranding.
enum AppConfig {
    static let appName = "Red String"

    /// Must match `com.apple.security.application-groups` in both entitlements files.
    static let appGroupID = "group.com.edwintang.redstring"

    /// Must match `com.apple.developer.icloud-container-identifiers` in both
    /// entitlements files.
    static let cloudContainerID = "iCloud.com.edwintang.redstring"

    /// Custom zone holding both partners' status records. Custom (not default)
    /// zones are required for both zone sharing and database subscriptions.
    static let coupleZoneName = "CoupleZone"

    /// Identifier passed to `WidgetCenter` reloads and declared by the widget.
    static let widgetKind = "RedStringStatusWidget"

    /// Minimum gap between nudges. Short on purpose: this exists to stop a
    /// double-tap sending twice while the first write is still in flight, not
    /// to ration affection. Sending a few hearts in a row is the point.
    static let nudgeCooldown: TimeInterval = 3

    /// Identifier for the photo/drawing widget.
    static let momentWidgetKind = "RedStringMomentWidget"

    /// Entries kept in the on-device history index. Metadata only, so this can
    /// be generous — CloudKit keeps everything regardless, and a fresh install
    /// pulls the whole zone back.
    static let momentHistoryLimit = 500

    /// How many recent moments keep their media files on this device. Older
    /// ones are fetched from CloudKit on demand when you scroll to them.
    static let momentImageCacheLimit = 60

    /// Hard ceiling on a voice memo. This is a "thinking of you" channel, not
    /// voicemail — a long recording is also a slow upload on a bad connection,
    /// and recording stops itself here rather than failing later.
    static let voiceMemoMaxDuration: TimeInterval = 60

    /// Loudness samples kept per voice memo. Enough to read as a waveform at
    /// full width, few enough that the metadata stays a few hundred bytes.
    static let voiceWaveformSampleCount = 48
}
