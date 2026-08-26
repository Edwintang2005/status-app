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

    /// Marks this status as an anniversary. The *receiving* device plays a
    /// full-screen animation built around `message` the first time the app is
    /// opened after it lands — see `Snapshot.pendingCelebration`. It rides on
    /// the status rather than being its own record type so that a celebration
    /// is still just a status: it shows on the home screen and in the widget
    /// like any other, and it's replaced the moment either of you moves on.
    var isCelebration: Bool = false

    private enum CodingKeys: String, CodingKey {
        case emoji, message, displayName, updatedAt, nudgeCount, lastNudgeAt
        case isCelebration
    }

    init(emoji: String,
         message: String,
         displayName: String,
         updatedAt: Date,
         nudgeCount: Int,
         lastNudgeAt: Date?,
         isCelebration: Bool = false) {
        self.emoji = emoji
        self.message = message
        self.displayName = displayName
        self.updatedAt = updatedAt
        self.nudgeCount = nudgeCount
        self.lastNudgeAt = lastNudgeAt
        self.isCelebration = isCelebration
    }

    /// Hand-written for the same reason `Snapshot`'s is, and because this type
    /// is *nested inside* that snapshot: a synthesised decoder treats a missing
    /// key as an error even when the property has a default, so a payload
    /// written by a build without `isCelebration` would fail to decode and take
    /// the whole cached snapshot down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "💭"
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        nudgeCount = try container.decodeIfPresent(Int.self, forKey: .nudgeCount) ?? 0
        lastNudgeAt = try container.decodeIfPresent(Date.self, forKey: .lastNudgeAt)
        isCelebration = try container.decodeIfPresent(Bool.self, forKey: .isCelebration) ?? false
    }

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

    /// The newest photo or doodle from the partner, ignoring voice memos.
    ///
    /// The widget draws *this* rather than `latestPartnerMoment`: a memo
    /// shouldn't blank out their last picture, because a waveform tile says far
    /// less at a glance than the photo it replaced. A waiting memo shows up as
    /// a badge over the picture instead.
    var latestPartnerVisualMoment: Moment?
    /// How many of the partner's voice memos haven't been listened to. Derived
    /// from the index rather than stored per-moment, so it can be recomputed
    /// when something is marked as heard — see `SharedStore.applyDerived`.
    var unheardVoiceMemoCount: Int = 0

    /// `updatedAt` of the last celebration status from the partner that this
    /// device has actually played. Stored rather than derived because "have we
    /// celebrated this one yet" has to survive a relaunch — that's the whole
    /// point of a greeting on first open — and comparing timestamps makes it
    /// idempotent when the same record is fetched twice.
    var lastCelebratedAt: Date?

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

    private enum CodingKeys: String, CodingKey {
        case mine, theirs, isPaired, lastSyncedAt, lastSeenPartnerNudgeCount
        case lastNudgeSentAt, latestPartnerMoment, latestOwnMoment
        case lastNotifiedMomentID, latestPartnerVisualMoment, unheardVoiceMemoCount
        case lastCelebratedAt
    }

    /// Hand-written for the same reason `Moment`'s is: synthesised `Codable`
    /// treats a missing key as an error, so a snapshot written by an earlier
    /// build would fail to decode outright and reset the widget to blank.
    /// Every key is optional here, and every field has a sane fallback.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mine = try container.decodeIfPresent(StatusPayload.self, forKey: .mine)
        theirs = try container.decodeIfPresent(StatusPayload.self, forKey: .theirs)
        isPaired = try container.decodeIfPresent(Bool.self, forKey: .isPaired) ?? false
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastSeenPartnerNudgeCount = try container
            .decodeIfPresent(Int.self, forKey: .lastSeenPartnerNudgeCount) ?? 0
        lastNudgeSentAt = try container.decodeIfPresent(Date.self, forKey: .lastNudgeSentAt)
        latestPartnerMoment = try container.decodeIfPresent(Moment.self, forKey: .latestPartnerMoment)
        latestOwnMoment = try container.decodeIfPresent(Moment.self, forKey: .latestOwnMoment)
        lastNotifiedMomentID = try container.decodeIfPresent(String.self, forKey: .lastNotifiedMomentID)
        latestPartnerVisualMoment = try container
            .decodeIfPresent(Moment.self, forKey: .latestPartnerVisualMoment)
            // Pre-voice-memo snapshots had only the one field, and back then
            // every moment was a picture.
            ?? latestPartnerMoment.flatMap { $0.isVoice ? nil : $0 }
        unheardVoiceMemoCount = try container
            .decodeIfPresent(Int.self, forKey: .unheardVoiceMemoCount) ?? 0
        lastCelebratedAt = try container.decodeIfPresent(Date.self, forKey: .lastCelebratedAt)
    }

    init(mine: StatusPayload?,
         theirs: StatusPayload?,
         isPaired: Bool,
         lastSyncedAt: Date?,
         lastSeenPartnerNudgeCount: Int,
         lastNudgeSentAt: Date?,
         latestPartnerMoment: Moment?,
         latestOwnMoment: Moment?,
         lastNotifiedMomentID: String?,
         latestPartnerVisualMoment: Moment? = nil,
         unheardVoiceMemoCount: Int = 0,
         lastCelebratedAt: Date? = nil) {
        self.mine = mine
        self.theirs = theirs
        self.isPaired = isPaired
        self.lastSyncedAt = lastSyncedAt
        self.lastSeenPartnerNudgeCount = lastSeenPartnerNudgeCount
        self.lastNudgeSentAt = lastNudgeSentAt
        self.latestPartnerMoment = latestPartnerMoment
        self.latestOwnMoment = latestOwnMoment
        self.lastNotifiedMomentID = lastNotifiedMomentID
        self.latestPartnerVisualMoment = latestPartnerVisualMoment
        self.unheardVoiceMemoCount = unheardVoiceMemoCount
        self.lastCelebratedAt = lastCelebratedAt
    }

    /// The partner's celebration status, if one has arrived that this device
    /// hasn't played yet — which is exactly what the greeting on first open is
    /// waiting for. `nil` once it's been shown, and `nil` for your own
    /// celebration: the animation is a gift, and you don't unwrap your own.
    var pendingCelebration: StatusPayload? {
        guard let theirs, theirs.isCelebration else { return nil }
        if let lastCelebratedAt, theirs.updatedAt <= lastCelebratedAt { return nil }
        return theirs
    }

    /// Newest in either direction, whatever its kind.
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

    /// Paired, with nothing from the other side yet — the state a new pair
    /// sits in until the first status arrives, and the one the widgets used to
    /// render as "not paired".
    static let previewWaiting = Snapshot(
        mine: StatusPayload(
            emoji: "💼",
            message: "working",
            displayName: "Me",
            updatedAt: Date(),
            nudgeCount: 0,
            lastNudgeAt: nil
        ),
        theirs: nil,
        isPaired: true,
        lastSyncedAt: Date(),
        lastSeenPartnerNudgeCount: 0,
        lastNudgeSentAt: nil,
        latestPartnerMoment: nil,
        latestOwnMoment: nil,
        lastNotifiedMomentID: nil,
        latestPartnerVisualMoment: nil,
        unheardVoiceMemoCount: 0
    )

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
        latestPartnerMoment: .previewPhoto,
        latestOwnMoment: nil,
        lastNotifiedMomentID: "preview-moment",
        latestPartnerVisualMoment: .previewPhoto,
        unheardVoiceMemoCount: 1
    )
}

/// Deliberately not behind `#if DEBUG`: `Snapshot.preview` above is what the
/// widget gallery renders, so this ships in Release too.
extension Moment {
    static let previewPhoto = Moment(id: "preview-moment",
                                     kind: .photo,
                                     caption: "morning ☕️",
                                     senderName: "Sam",
                                     sentAt: Date().addingTimeInterval(-5_400),
                                     fromMe: false)
}
