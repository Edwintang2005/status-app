import Foundation

/// Every identifier that has to stay in lockstep with the entitlements files
/// and `project.yml`. Change these four strings together when rebranding.
enum AppConfig {
    static let appName = "Red String"

    /// Must match `com.apple.security.application-groups` in all six entitlements
    /// files (app Debug and Release, widget, notification service, notification content, share).
    static let appGroupID = "group.com.edwintang.redstring"

    /// Must match `com.apple.developer.icloud-container-identifiers` in all six
    /// entitlements files (app Debug and Release, widget, notification service, notification content, share).
    static let cloudContainerID = "iCloud.com.edwintang.redstring"

    /// Custom zone holding both partners' status records. Custom (not default)
    /// zones are required for both zone sharing and database subscriptions.
    static let coupleZoneName = "CoupleZone"

    /// Where reports and blocks are sent (guideline 1.2). Acted on within 24 hours.
    static let supportEmail = "edwintang2005@gmail.com"
    /// Bump to make everyone re-accept the terms on next launch.
    static let termsVersion = 1

    /// Identifier passed to `WidgetCenter` reloads and declared by the widget.
    static let widgetKind = "RedStringStatusWidget"

    /// Minimum gap between nudges. Short on purpose: this exists to stop a
    /// double-tap sending twice while the first write is still in flight, not
    /// to ration affection. Sending a few hearts in a row is the point.
    static let nudgeCooldown: TimeInterval = 3
    /// How long the lock-screen heart shows ✓ once a slow send is handed to iCloud.
    static let nudgeSentNotice: TimeInterval = 4
    /// A tap of ours this far before this phone's latest counts as this phone's,
    /// for wording its push (a burst of slow taps lands together).
    static let nudgeEchoWindow: TimeInterval = 10 * 60
    /// How long after sending an own moment it can still be deleted for both of
    /// you; one that never reached iCloud can always be.
    static let momentDeleteWindow: TimeInterval = 5 * 60
    /// A partner moment removed within this of its sending gets a notice; an
    /// older one leaving (history, a fresh start) goes quietly.
    static let removalNoticeWindow: TimeInterval = 24 * 60 * 60
    /// How far a date may run ahead of the server's save time before it's
    /// capped, and how far ahead of this phone's clock a stored mark may sit
    /// before it counts as stale (`TrustedTime`). A day, not minutes: people set
    /// clocks ahead on purpose, and a cap that trips on them splits history
    /// entries and receipts that key on the exact stamp. It's for absurd dates.
    static let clockSkewAllowance: TimeInterval = 24 * 60 * 60
    /// A partner moment's `sentAt` past the server's creation time by more than
    /// this is their clock running ahead: it orders the history and judges news,
    /// and no key depends on it (unlike a status's `wordsAt`), so it's held tight.
    static let momentClockLeeway: TimeInterval = 2 * 60
    /// A nudge older than this on arrival is worded "earlier" and never breaks
    /// through Focus; at most one nudge per interval does. Generous, because the
    /// age is judged on the sender's clock against this phone's.
    static let nudgeStaleAfter: TimeInterval = 15 * 60
    static let nudgeBreakthroughInterval: TimeInterval = 10 * 60

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

    /// Entries kept in the on-device history index. Metadata only (~230 bytes
    /// each: 5,000 is ~1.1 MB, decoded in tens of ms), so it can be generous —
    /// CloudKit keeps everything regardless, and a fresh install pulls the whole zone back.
    static let momentHistoryLimit = 5_000

    /// How many recent moments keep their thumbnail (~30–60 KB each) on this
    /// device; older tiles fetch theirs as they scroll into view. Favourites and
    /// unsent sends keep theirs whatever their age (`MediaRetention`).
    static let momentThumbnailLimit = 500

    /// How many recent moments keep their media files on this device. Older
    /// ones are fetched from CloudKit on demand when you scroll to them.
    static let momentImageCacheLimit = 60

    /// Hard ceiling on a voice memo. Four minutes is long enough for a real
    /// message but keeps the file under two megabytes — small enough to nearly
    /// always finish uploading inside the background grace period after the
    /// app is switched away, which is what makes interrupted sends rare
    /// rather than routine. Recording stops itself here rather than failing
    /// later on the upload.
    static let voiceMemoMaxDuration: TimeInterval = 240

    /// Loudness samples kept per voice memo. Enough to read as a waveform at
    /// full width, few enough that the metadata stays a few hundred bytes.
    static let voiceWaveformSampleCount = 48

    /// MetricKit reports kept for Diagnostics (`SharedStore.crashReports`).
    static let crashReportLimit = 20

    /// Blank-sheet measurements kept for Diagnostics (`SharedStore.layoutGlitches`).
    static let layoutGlitchLimit = 10

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

    /// Characters, not bytes: a status is a glance, a caption a line. Enforced
    /// in the composers and again in `AppModel`, so a banner reply obeys it too.
    static let statusMessageMaxLength = 80
    /// Received-side caps for fields the composers don't limit themselves: an
    /// emoji is one or two graphemes, a name is a name.
    static let statusEmojiMaxLength = 2
    static let displayNameMaxLength = 40
    /// Received nudge counts are clamped here, far past any real use, so a
    /// crafted `Int.max` can't trap the increment.
    static let nudgeCountCeiling = 1_000_000_000
    static let captionMaxLength = 140

    /// Records missed by a fetch are owed (`SharedStore.UnreadableTally`) and
    /// fetched again by ID — at most this often per process — until read, deleted,
    /// or this old; never more than the limit, so a zone can't grow it without end.
    static let owedRetrySpacing: TimeInterval = 60
    static let owedRecordLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let owedRecordLimit = 500
    /// An extension's share of a retry: its process has megabytes and seconds, not minutes.
    static let owedRetryExtensionLimit = 50
    /// An extension's wait after a retry that read nothing (a locked phone).
    static let owedRetryBlindSpacing: TimeInterval = 10 * 60
    /// A retry has its own bound: a stall mustn't fail the fetch it follows. An
    /// extension's is shorter, and it skips the retry once its pass has used the
    /// budget: the widget's whole refresh has `widgetDeadline` (8 s).
    static let owedRetryDeadline: TimeInterval = 5
    static let owedRetryExtensionDeadline: TimeInterval = 2.5
    static let owedRetryExtensionBudget: TimeInterval = 3
    /// Spaced looks (`owedRetrySpacing` apart) by the app, with its keys, at a held
    /// resync too big for the owed list before it moves on and owes what fits.
    static let heldResyncGiveUpPasses = 3

    /// "The shared zone is gone" must be seen twice, this far apart, before a
    /// device unlinks itself and wipes: the invite-close handshake takes the
    /// partner off the share for up to ten seconds, and one unlucky refresh
    /// in that window must not cost them their unsent media.
    static let zoneGoneConfirmation: TimeInterval = 120

    /// Ceiling on any CloudKit call made from a widget or its intent — WidgetKit
    /// kills the process past its budget, and a kill mid-write leaves claims unreleased.
    static let widgetDeadline: TimeInterval = 8

    /// Ceilings on waiting for an upload and on refreshes. CloudKit's own resource
    /// timeout is seven days, so on bad signal an operation can sit for hours —
    /// and while it does, the re-entrancy guards block every retry behind it.
    /// Past `uploadDeadline` the caller stops waiting but the upload runs on,
    /// still in flight, while it moves (`uploadStallTimeout`); a timed-out
    /// refresh is abandoned and finishes or fails on its own (its
    /// apply-before-token order makes that safe).
    static let uploadDeadline: TimeInterval = 180
    /// An upload whose bytes haven't moved for this long is cancelled and left
    /// pending (`UploadWatch`), checked every `uploadTickInterval`.
    static let uploadStallTimeout: TimeInterval = 90
    /// How long the app's retry pass leaves a send the share sheet started
    /// (`ShareIntake.isClaimed`): past the sheet's own wait, with room to land.
    static let shareUploadHold: TimeInterval = uploadDeadline + 60
    /// The rest of the hold once the sheet is closed mid-send: long enough for a
    /// save already handed to iCloud to land, short enough that the app sends soon.
    static let shareClosedHold: TimeInterval = 90
    static let uploadTickInterval: TimeInterval = 5
    static let refreshDeadline: TimeInterval = 120
    /// The app's sweep starts no batch past this (`CloudSync.refresh`): it returns
    /// what it filed, incomplete, to be announced, rather than be cancelled at
    /// `refreshDeadline` with its announcements lost; the next refresh carries on.
    static let sweepBudget: TimeInterval = 90
    /// Fetches failed in a row before Home's footer says it couldn't sync: one is
    /// routine (a blip, a backgrounded app), three is something to know about.
    static let fetchFailuresShown = 3
    /// A favourite whose full copy didn't download waits this long before a
    /// recovery pass asks again (opening it still fetches at once).
    static let favouriteRetryInterval: TimeInterval = 60 * 60
    /// Status, receipt, anniversary and subscription writes: small records, so
    /// anything slower is a stall. Abandoning one is safe — the published flags
    /// stay down and the next refresh republishes.
    static let publishDeadline: TimeInterval = 30
    /// A fresh start's clear: a whole-zone fetch plus batched deletions. An
    /// abandoned pass is safe — it re-runs from the top — and the local clear
    /// only follows a pass that finished.
    static let freshStartDeadline: TimeInterval = 300

    /// Refresh attempts after the network comes back, each this long after the
    /// last failed one — the first often beats DNS or a VPN reconnecting.
    static let reconnectRetryDelays: [TimeInterval] = [0, 5, 20]
    /// How long the path must stay down before Home says "offline" — a
    /// Wi-Fi↔cellular handoff drops it for under a second.
    static let offlineCardDelay: TimeInterval = 1.5

    /// After a send fails on a full iCloud, automatic retries wait this long;
    /// the home footer's tap still retries at once.
    static let storageFullRetryInterval: TimeInterval = 60 * 60
    /// How long an automatic retry pass skips a send iCloud refused outright (`SendFailure.rejected`).
    static let rejectedUploadRetryInterval: TimeInterval = 6 * 60 * 60
    /// A throttled request (`requestRateLimited`, `zoneBusy`, `serviceUnavailable`)
    /// without a retry-after of its own waits this long before automatic retries.
    static let throttleDefaultDelay: TimeInterval = 30
    /// The most a server's retry-after may hold automatic retries: a crafted
    /// or absurd figure can't park the queue for days.
    static let throttleMaxDelay: TimeInterval = 60 * 60
    /// A status republish that keeps failing for another reason backs off from
    /// this, doubling per failure up to `statusRetryMaxDelay`.
    static let statusRetryBaseDelay: TimeInterval = 30
    static let statusRetryMaxDelay: TimeInterval = 60 * 60

    /// How far ahead of this phone's clock a server status stamp may sit and
    /// still count as a status set later than ours. Past it, a clock that ran
    /// ahead wrote it, and ours — set now — is the newer one.
    static let statusStampLeeway: TimeInterval = 2 * 60

    /// Receipts wait this long after the last moment marked seen, so paging
    /// through a carousel is one write, not one per page; backgrounding flushes.
    static let receiptDebounce: TimeInterval = 5

    /// Launch re-asserts the push subscriptions at most this often (a pairing
    /// change and a reinstall start over).
    static let subscriptionCheckInterval: TimeInterval = 24 * 60 * 60
    /// A readiness answer this fresh is reused by the next fetch: launch checks
    /// it, then refreshes straight after.
    static let readinessReuseWindow: TimeInterval = 15
    /// Launch skips its own fetch when one finished this recently (the scene
    /// becoming active also refreshes).
    static let launchRefreshCoalesceWindow: TimeInterval = 10

    /// The memories archive fetches this many moments' media at once, and gives
    /// each this long before listing it as unrecovered.
    static let archiveFetchConcurrency = 4
    static let archiveItemDeadline: TimeInterval = 60

    /// How often the owner's refresh pass re-counts who is on the share —
    /// one share fetch, for the "someone else joined" warning.
    static let shareMemberCheckInterval: TimeInterval = 60 * 60
    /// The same once the link is closed: nobody new can join, so daily, and a
    /// cold launch doesn't repeat it (`SharedStore.shareCheckedAt`).
    static let closedShareCheckInterval: TimeInterval = 24 * 60 * 60

    /// How long a copied invite link, report or diagnostics report stays on
    /// the clipboard — long enough to paste, not to linger for any app to read.
    static let clipboardLifetime: TimeInterval = 10 * 60
}
