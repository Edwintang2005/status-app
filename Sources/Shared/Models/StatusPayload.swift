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

    /// The server holds only the newest moment per person, at a fixed name;
    /// each device accumulates its own history locally.
    var momentRecordName: String {
        switch self {
        case .owner: return "moment-owner"
        case .participant: return "moment-participant"
        }
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
    /// Local nickname override for the partner. Never synced — each side picks
    /// what they want to see.
    var partnerNickname: String?
    var isPaired: Bool
    var lastSyncedAt: Date?

    /// Highest `nudgeCount` already surfaced as a notification on this device.
    var lastSeenPartnerNudgeCount: Int
    /// When this device last *sent* a nudge, for cooldown enforcement.
    var lastNudgeSentAt: Date?

    /// Newest first, both directions, capped at `AppConfig.momentHistoryLimit`.
    /// Image bytes live on disk in the App Group; this is only the index.
    var moments: [Moment] = []
    /// The partner moment id already surfaced as a notification here.
    var lastSeenMomentID: String?

    static let empty = Snapshot(
        mine: nil,
        theirs: nil,
        partnerNickname: nil,
        isPaired: false,
        lastSyncedAt: nil,
        lastSeenPartnerNudgeCount: 0,
        lastNudgeSentAt: nil,
        moments: [],
        lastSeenMomentID: nil
    )

    /// The newest thing the partner sent — what the moment widget shows.
    var latestPartnerMoment: Moment? {
        moments.first { !$0.fromMe }
    }

    var latestOwnMoment: Moment? {
        moments.first { $0.fromMe }
    }

    /// Nickname wins over whatever the partner calls themselves.
    var partnerDisplayName: String {
        if let nickname = partnerNickname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty {
            return nickname
        }
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
        partnerNickname: nil,
        isPaired: true,
        lastSyncedAt: Date(),
        lastSeenPartnerNudgeCount: 3,
        lastNudgeSentAt: nil,
        moments: [
            Moment(id: "preview-moment",
                   kind: .photo,
                   caption: "morning ☕️",
                   senderName: "Sam",
                   sentAt: Date().addingTimeInterval(-5_400),
                   fromMe: false)
        ],
        lastSeenMomentID: "preview-moment"
    )
}
