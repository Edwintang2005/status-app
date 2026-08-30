import Foundation

/// One person's current status. Exactly one of these exists per partner in the
/// shared CloudKit zone.
struct StatusPayload: Codable, Hashable {
    var emoji: String
    var message: String
    /// What this person calls themselves.
    var displayName: String
    var updatedAt: Date

    /// Monotonic counter bumped per nudge; the receiver compares it to the last
    /// count seen, keeping nudge delivery idempotent across duplicate fetches.
    var nudgeCount: Int
    var lastNudgeAt: Date?

    /// Anniversary marker: the receiving device plays a full-screen animation on
    /// first open (see `Snapshot.pendingCelebration`). Rides on the status so a
    /// celebration still renders like any other status.
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

    /// Hand-written: synthesised decoding errors on missing keys, so a payload
    /// from an older build would fail and take the whole cached snapshot down.
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

/// Which side of the pair this device is; the role decides the record names each
/// device writes, so neither phone needs the other's CloudKit user ID.
enum PairRole: String, Codable {
    case owner
    case participant

    var statusRecordName: String {
        switch self {
        case .owner: return "status-owner"
        case .participant: return "status-participant"
        }
    }

    /// Nudges are their own record type so a nudge can carry a visible push while
    /// a status change stays silent — `CKDatabaseSubscription` filters by type.
    var nudgeRecordName: String {
        switch self {
        case .owner: return "nudge-owner"
        case .participant: return "nudge-participant"
        }
    }

    /// One read-receipt record per side, carrying that side's seen-map.
    var receiptRecordName: String {
        switch self {
        case .owner: return "receipt-owner"
        case .participant: return "receipt-participant"
        }
    }

    /// Moment records are `moment-<role>-<uuid>`; the role in the name tells a
    /// device's own sends from its partner's without an extra field.
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
    /// iCloud user record name at pairing time, so "zone not found" can tell
    /// partner-unlinked from switched-account. `nil` on pairings made before
    /// this field existed (optional, so those still decode).
    var userRecordName: String?

    init(role: PairRole,
         zoneName: String,
         zoneOwnerName: String,
         pairedAt: Date,
         userRecordName: String? = nil) {
        self.role = role
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.pairedAt = pairedAt
        self.userRecordName = userRecordName
    }
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
    /// When a nudge last failed, so the lock-screen heart can show it (the widget
    /// intent can't show an alert). Cleared on the next claim or success.
    var lastNudgeFailedAt: Date?

    /// Whether `mine` has reached CloudKit; stays `false` offline and is
    /// republished on the next refresh — the status twin of `Moment.uploaded`.
    var myStatusPublished: Bool = true

    /// Only the newest in each direction; the full history lives in `MomentIndex`
    /// so widget renders stay small.
    var latestPartnerMoment: Moment?
    var latestOwnMoment: Moment?
    /// Partner moment id most recently announced by a notification (not the same
    /// as `Moment.seen`). Kept for older builds that only read this field.
    var lastNotifiedMomentID: String?
    /// The last few announced moment ids, newest first — a single watermark
    /// can't dedup several moments arriving in quick succession.
    var notifiedMomentIDs: [String] = []

    /// Newest partner photo/doodle, ignoring voice memos. The widget draws this
    /// rather than `latestPartnerMoment` so a memo doesn't blank out the picture.
    var latestPartnerVisualMoment: Moment?
    /// Partner voice memos not yet listened to. Derived from the index so it can
    /// be recomputed — see `SharedStore.applyDerived`.
    var unheardVoiceMemoCount: Int = 0

    /// `updatedAt` of the last partner celebration this device has played.
    /// Stored so it survives relaunch; timestamp compare keeps it idempotent.
    var lastCelebratedAt: Date?

    /// `updatedAt` of the partner status last written onto a push banner by the
    /// notification extension — the status twin of `lastSeenPartnerNudgeCount`.
    /// Needed because the widget often consumes the change-token delta first.
    var lastAnnouncedPartnerStatusAt: Date?

    /// Whether this device's read-receipt record is behind its local seen-state.
    /// Set by `markSeen` and the Settings toggle; cleared by a successful
    /// `publishReceipts`, so a failed publish retries on the next refresh.
    var receiptsDirty: Bool = false

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
        case lastCelebratedAt, notifiedMomentIDs
        case lastNudgeFailedAt, myStatusPublished
        case lastAnnouncedPartnerStatusAt
        case receiptsDirty
    }

    /// Hand-written: synthesised `Codable` errors on missing keys, so a snapshot
    /// from an earlier build would reset the widget to blank. Every field falls back.
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
        // Absent key = legacy snapshot; explicit null = the only picture was
        // deleted. Folding the two resurrected deleted photos in the widget.
        if container.contains(.latestPartnerVisualMoment) {
            latestPartnerVisualMoment = try container
                .decodeIfPresent(Moment.self, forKey: .latestPartnerVisualMoment)
        } else {
            // Legacy fallback: pre-voice-memo, every moment was a picture.
            latestPartnerVisualMoment = latestPartnerMoment.flatMap { $0.isVoice ? nil : $0 }
        }
        unheardVoiceMemoCount = try container
            .decodeIfPresent(Int.self, forKey: .unheardVoiceMemoCount) ?? 0
        lastCelebratedAt = try container.decodeIfPresent(Date.self, forKey: .lastCelebratedAt)
        notifiedMomentIDs = try container
            .decodeIfPresent([String].self, forKey: .notifiedMomentIDs) ?? []
        lastNudgeFailedAt = try container.decodeIfPresent(Date.self, forKey: .lastNudgeFailedAt)
        // Assume published for pre-field snapshots to avoid re-pushing an old status.
        myStatusPublished = try container
            .decodeIfPresent(Bool.self, forKey: .myStatusPublished) ?? true
        lastAnnouncedPartnerStatusAt = try container
            .decodeIfPresent(Date.self, forKey: .lastAnnouncedPartnerStatusAt)
        receiptsDirty = try container.decodeIfPresent(Bool.self, forKey: .receiptsDirty) ?? false
    }

    /// Hand-written: `latestPartnerVisualMoment`'s nil must be written as an
    /// explicit null — see the decoder above.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(mine, forKey: .mine)
        try container.encodeIfPresent(theirs, forKey: .theirs)
        try container.encode(isPaired, forKey: .isPaired)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(lastSeenPartnerNudgeCount, forKey: .lastSeenPartnerNudgeCount)
        try container.encodeIfPresent(lastNudgeSentAt, forKey: .lastNudgeSentAt)
        try container.encodeIfPresent(latestPartnerMoment, forKey: .latestPartnerMoment)
        try container.encodeIfPresent(latestOwnMoment, forKey: .latestOwnMoment)
        try container.encodeIfPresent(lastNotifiedMomentID, forKey: .lastNotifiedMomentID)
        if let latestPartnerVisualMoment {
            try container.encode(latestPartnerVisualMoment, forKey: .latestPartnerVisualMoment)
        } else {
            try container.encodeNil(forKey: .latestPartnerVisualMoment)
        }
        try container.encode(unheardVoiceMemoCount, forKey: .unheardVoiceMemoCount)
        try container.encodeIfPresent(lastCelebratedAt, forKey: .lastCelebratedAt)
        try container.encode(notifiedMomentIDs, forKey: .notifiedMomentIDs)
        try container.encodeIfPresent(lastNudgeFailedAt, forKey: .lastNudgeFailedAt)
        try container.encode(myStatusPublished, forKey: .myStatusPublished)
        try container.encodeIfPresent(lastAnnouncedPartnerStatusAt,
                                      forKey: .lastAnnouncedPartnerStatusAt)
        try container.encode(receiptsDirty, forKey: .receiptsDirty)
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

    /// Whether a notification for this moment has already been shown on this
    /// device, by either the app or the service extension.
    func hasAnnounced(_ momentID: String) -> Bool {
        lastNotifiedMomentID == momentID || notifiedMomentIDs.contains(momentID)
    }

    /// Records that a notification for this moment is being shown. Bounded: only
    /// needs to cover pushes arriving faster than they can be announced.
    mutating func recordAnnounced(_ momentID: String) {
        lastNotifiedMomentID = momentID
        guard !notifiedMomentIDs.contains(momentID) else { return }
        notifiedMomentIDs.insert(momentID, at: 0)
        if notifiedMomentIDs.count > 8 {
            notifiedMomentIDs.removeLast(notifiedMomentIDs.count - 8)
        }
    }

    /// The partner's celebration status that hasn't been played yet; `nil` once
    /// shown, and always `nil` for your own celebration.
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

    /// The partner's self-chosen name; deliberately no local override.
    var partnerDisplayName: String {
        let synced = theirs?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (synced?.isEmpty == false ? synced! : "Partner")
    }

    /// Paired, with nothing from the other side yet.
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

/// Deliberately not behind `#if DEBUG`: the widget gallery renders
/// `Snapshot.preview`, so this ships in Release too.
extension Moment {
    static let previewPhoto = Moment(id: "preview-moment",
                                     kind: .photo,
                                     caption: "morning ☕️",
                                     senderName: "Sam",
                                     sentAt: Date().addingTimeInterval(-5_400),
                                     fromMe: false)
}
