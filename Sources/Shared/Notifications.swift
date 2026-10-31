import Foundation

/// Notification categories and actions. Shared because the app registers and
/// handles them while the notification service stamps them on rewritten banners.
enum NotificationCategory {
    static let status = "status"
    static let nudge = "nudge"
    static let moment = "moment"
    /// A local milestone reminder (`MilestoneReminderPlan`); opens the count.
    static let milestone = "milestone"

    /// userInfo key the notification service stamps (value: the category) on a
    /// banner worded from unencrypted fields alone, so the app's sweep supersedes it.
    static let heldBannerKey = "held-banner"
    /// userInfo key on a notification quietened to "list only" by this phone's
    /// preferences: the open app files it rather than showing a banner.
    static let listOnlyKey = "list-only"
    /// userInfo key on a banner `BannerUpkeep` rewrote: already seen once, so the
    /// open app files it rather than showing it again.
    static let revisedKey = "revised"

    enum Action {
        /// One-tap heart back, offered on every category.
        static let heartBack = "heart-back"
        /// Text reply on a status banner; the words become this device's status.
        static let replyStatus = "reply-status"
        /// On a moment banner: opens the composer straight into the camera.
        static let replyPhoto = "reply-photo"
    }
}

/// What a banner is about, stamped in its userInfo by whoever words it (the
/// service's `PushBannerPolicy.Plan`, `NotificationManager`), so a later pass
/// can find it again (`BannerUpkeep`). Moment IDs are plaintext in the record
/// name already, and userInfo never leaves the phone.
enum BannerSubject: Equatable, Sendable {
    case moment(String)
    /// The partner's status; only the newest banner of these stays.
    case status
    case hearts

    static let key = "subject"
    /// The banner wanted its moment's thumbnail or recording and went out without it.
    static let wantsAttachmentKey = "wants-attachment"

    var stamp: String {
        switch self {
        case .moment(let id): "moment:\(id)"
        case .status: "status"
        case .hearts: "hearts"
        }
    }

    init?(stamp: String) {
        switch stamp {
        case "status": self = .status
        case "hearts": self = .hearts
        default:
            guard stamp.hasPrefix("moment:") else { return nil }
            let id = String(stamp.dropFirst("moment:".count))
            guard !id.isEmpty else { return nil }
            self = .moment(id)
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let stamp = userInfo[Self.key] as? String else { return nil }
        self.init(stamp: stamp)
    }
}

extension Notification.Name {
    /// Something outside the model changed the store (the lock-screen intent, a
    /// link that ended): re-read it *and* refresh.
    static let pairingDidChange = Notification.Name("RedStringPairingDidChange")
    /// The store changed and the poster handles any fetch (the model's own
    /// refresh, `refreshQuietly`, a foreground banner): re-read it only.
    static let snapshotDidChange = Notification.Name("RedStringSnapshotDidChange")
    static let pairingDidFail = Notification.Name("RedStringPairingDidFail")
    /// Object is the `CKShare.Metadata` from the tapped link.
    static let inviteDidArrive = Notification.Name("RedStringInviteDidArrive")
}
