import Foundation

/// Every identifier that has to stay in lockstep with the entitlements files
/// and `project.yml`. Change these four strings together when rebranding.
enum AppConfig {
    static let appName = "Red String"

    /// Must match `com.apple.security.application-groups` in all four entitlements
    /// files (app Debug and Release, widget, notification service).
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

    /// How long the lock-screen heart admits a failed nudge (a slashed heart)
    /// before quietly offering itself again. Long enough to still be there at
    /// the next glance; short enough not to read as a permanent breakage.
    static let nudgeFailureNotice: TimeInterval = 10 * 60

    /// Identifier for the photo/drawing widget.
    static let momentWidgetKind = "RedStringMomentWidget"

    /// Identifier for the lock-screen nudge widget. In this file so
    /// `SharedStore.reloadWidgets` and the widget's declaration can't drift
    /// apart — a kind that never gets reloaded shows stale pairing state for
    /// up to an hour.
    static let nudgeWidgetKind = "RedStringNudgeWidget"

    /// Entries kept in the on-device history index. Metadata only, so this can
    /// be generous — CloudKit keeps everything regardless, and a fresh install
    /// pulls the whole zone back.
    static let momentHistoryLimit = 500

    /// How many recent moments keep their media files on this device. Older
    /// ones are fetched from CloudKit on demand when you scroll to them.
    static let momentImageCacheLimit = 60

    /// Hard ceiling on a voice memo. Three minutes is long enough for a real
    /// message but keeps the file near a megabyte — small enough to nearly
    /// always finish uploading inside the background grace period after the
    /// app is switched away, which is what makes interrupted sends rare
    /// rather than routine. Recording stops itself here rather than failing
    /// later on the upload.
    static let voiceMemoMaxDuration: TimeInterval = 180

    /// Loudness samples kept per voice memo. Enough to read as a waveform at
    /// full width, few enough that the metadata stays a few hundred bytes.
    static let voiceWaveformSampleCount = 48

    /// Entries kept in the local status history log, both sides together. Sized
    /// to hold both partners' full cloud logs (`statusLogLimit` each).
    static let statusHistoryLimit = 300

    /// `StatusLog` records each side keeps in CloudKit. Every status change is a
    /// record, so this caps the zone's growth; the publisher deletes its own
    /// oldest entries past it, and both devices drop them from the local log.
    static let statusLogLimit = 150

    /// Seen-moments carried in a read-receipt record. Covers everything a
    /// sender could still be wondering about without growing unboundedly.
    static let receiptMapLimit = 100
}
