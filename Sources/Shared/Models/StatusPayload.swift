import Foundation

/// One person's current status. Exactly one of these exists per partner in the
/// shared CloudKit zone.
struct StatusPayload: Codable, Hashable {
    var emoji: String
    var message: String
    /// What this person calls themselves. The other side may override it
    /// locally with a nickname — see `Snapshot.partnerDisplayName`.
    var displayName: String
    var updatedAt: Date

    /// Monotonic counter, bumped on every nudge sent. The receiving side
    /// compares it against the last count it saw to decide whether to fire a
    /// local notification, which makes nudge delivery idempotent even if the
    /// same record is fetched twice.
    var nudgeCount: Int
    var lastNudgeAt: Date?

    static let placeholder = StatusPayload(
        emoji: "💭",
        message: "no status yet",
        displayName: "Partner",
        updatedAt: .distantPast,
        nudgeCount: 0,
        lastNudgeAt: nil
    )

    static func initial(displayName: String) -> StatusPayload {
        StatusPayload(
            emoji: "👋",
            message: "just joined",
            displayName: displayName,
            updatedAt: Date(),
            nudgeCount: 0,
            lastNudgeAt: nil
        )
    }
}

/// Which side of the pair this device is. The role also decides the record
/// name each device writes to, so neither phone needs to know the other's
/// CloudKit user ID.
enum PairRole: String, Codable {
    case owner
    case participant

    var statusRecordName: String {
        switch self {
        case .owner: return "status-owner"
        case .participant: return "status-participant"
        }
    }

    /// Nudges are their own record type, not a field on `Status`, so that a
    /// nudge can carry a *visible* push while a status change stays silent —
    /// `CKDatabaseSubscription` filters by record type.
    var nudgeRecordName: String {
        switch self {
        case .owner: return "nudge-owner"
        case .participant: return "nudge-participant"
        }
    }

    /// Moments are one record each, named `moment-<role>-<uuid>`. The role in
    /// the name is how a device tells its own sends from its partner's without
    /// an extra field or a lookup.
    var momentRecordPrefix: String { "moment-\(rawValue)-" }

    func momentRecordName(id: String) -> String { momentRecordPrefix + id }

    /// The moment id back out of a record name, or `nil` if it isn't ours.
    func momentID(fromRecordName name: String) -> String? {
        name.hasPrefix(momentRecordPrefix)
            ? String(name.dropFirst(momentRecordPrefix.count))
            : nil
    }

    var other: PairRole {
        self == .owner ? .participant : .owner
    }
}

/// Persisted once the pair is established; tells `CloudSync` which database
/// and zone to talk to.
struct PairingInfo: Codable, Hashable {
    var role: PairRole
    var zoneName: String
    /// `CKCurrentUserDefaultName` for the owner, otherwise the owner's CloudKit
    /// user record name taken from the accepted share metadata.
    var zoneOwnerName: String
    var pairedAt: Date
}

/// Everything the widget needs, cached in the App Group so it can render
/// instantly and without network.
struct Snapshot: Codable, Hashable {
    var mine: StatusPayload?
    var theirs: StatusPayload?
    var isPaired: Bool
    var lastSyncedAt: Date?

    /// Highest `nudgeCount` already surfaced as a notification on this device.
    var lastSeenPartnerNudgeCount: Int
    /// When this device last *sent* a nudge, for cooldown enforcement.
    var lastNudgeSentAt: Date?

    /// Only the newest in each direction. The widget decodes this snapshot on
    /// every render, so the full history deliberately lives elsewhere — see
    /// `MomentIndex`.
    var latestPartnerMoment: Moment?
    var latestOwnMoment: Moment?
    /// The partner moment id already announced by a notification here. Not the
    /// same as `Moment.seen`, which is about the user actually looking at it.
    var lastNotifiedMomentID: String?

    static let empty = Snapshot(
        mine: nil,
        theirs: nil,
        isPaired: false,
        lastSyncedAt: nil,
        lastSeenPartnerNudgeCount: 0,
        lastNudgeSentAt: nil,
        latestPartnerMoment: nil,
        latestOwnMoment: nil,
        lastNotifiedMomentID: nil
    )

    /// Newest in either direction — what the home card shows, so sending
    /// something gives you visible confirmation.
    var latestMoment: Moment? {
        [latestPartnerMoment, latestOwnMoment]
            .compactMap { $0 }
            .max { $0.sentAt < $1.sentAt }
    }

    /// Whatever the partner calls themselves. There is deliberately no local
    /// override: a person's name is theirs to set, and the name that arrives
    /// with a moment is the name that gets shown.
    var partnerDisplayName: String {
        let synced = theirs?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (synced?.isEmpty == false ? synced! : "Partner")
    }

    /// A snapshot with plausible content, for widget galleries and previews.
    static let preview = Snapshot(
        mine: StatusPayload(
            emoji: "💼",
            message: "working",
            displayName: "Me",
            updatedAt: Date(),
            nudgeCount: 0,
            lastNudgeAt: nil
        ),
        theirs: StatusPayload(
            emoji: "🥰",
            message: "missing you",
            displayName: "Sam",
            updatedAt: Date().addingTimeInterval(-1_200),
            nudgeCount: 3,
            lastNudgeAt: Date().addingTimeInterval(-3_600)
        ),
        isPaired: true,
        lastSyncedAt: Date(),
        lastSeenPartnerNudgeCount: 3,
        lastNudgeSentAt: nil,
        latestPartnerMoment: Moment(id: "preview-moment",
                                    kind: .photo,
                                    caption: "morning ☕️",
                                    senderName: "Sam",
                                    sentAt: Date().addingTimeInterval(-5_400),
                                    fromMe: false),
        latestOwnMoment: nil,
        lastNotifiedMomentID: "preview-moment"
    )
}
