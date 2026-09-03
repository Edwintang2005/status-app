import CloudKit
import Foundation
import os

/// Errors surfaced to the UI. Anything else is passed through as the raw
/// `CKError` so the message in Settings stays honest.
enum SyncError: LocalizedError {
    case notPaired
    case iCloudUnavailable(CKAccountStatus)
    case shareURLMissing
    /// Refused to close the invite link because a participant was still
    /// public after promotion — closing then would have removed them. Carries
    /// which step refused, so the diagnostics report can say.
    case couldNotSecureShare(String)
    /// Accepted an invite, but the shared zone never appeared.
    case shareUnavailable
    /// The shared zone is gone: the other person unlinked, and this device has
    /// just found out.
    case linkEnded
    /// Different iCloud account than the pairing's: the zone looks missing,
    /// but wiping local state would destroy an intact pairing.
    case differentAccount
    /// Settings' plain close refused: someone has joined through the link, so
    /// closing here would evict them (that's the Diagnostics handshake).
    case inviteInUse

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "This device isn't paired yet."
        case .iCloudUnavailable(let status):
            switch status {
            case .noAccount:
                return "Sign in to iCloud in Settings to use \(AppConfig.appName)."
            case .restricted:
                return "iCloud is restricted on this device."
            case .temporarilyUnavailable:
                return "iCloud is temporarily unavailable. Try again shortly."
            default:
                return "iCloud isn't available right now."
            }
        case .shareURLMissing:
            return "CloudKit didn't return an invite link. Try again."
        case .couldNotSecureShare(let detail):
            return "Couldn't close the invite link safely; it was reopened. "
                + "Your partner may have lost access — if their app unlinks, "
                + "send them the invite link to rejoin. (\(detail))"
        case .shareUnavailable:
            // Mismatched CloudKit environments look identical from here and
            // are covered by "the same build".
            return "Couldn't open the shared space. Ask them to send a fresh "
                + "invite link, and check you're both on the same build of "
                + "\(AppConfig.appName)."
        case .linkEnded:
            // Doesn't assert why: an unlink and a never-reachable zone look
            // the same from here.
            return "The shared space is no longer available. Everything shared "
                + "has been removed from this device — pair again to start over."
        case .differentAccount:
            return "This device is signed into a different iCloud account than "
                + "the one you paired with. Sign back into that account to see "
                + "your shared space, or unlink from Settings."
        case .inviteInUse:
            return "Your partner joined through this link, so closing it here would "
                + "remove them. Use Settings → Diagnostics → Secure invite instead."
        }
    }
}

/// What the server says about the owner's invite link.
enum InviteState: Sendable, Equatable {
    /// Still joinable, carrying the link to hand over.
    case open(URL)
    /// The share is there but no longer accepts joins from the link — either
    /// the partner arrived or the owner closed it by hand. Still carries the
    /// URL: the same link re-admits the existing partner on a new phone,
    /// while staying useless to anyone else.
    case closed(URL?)
    /// No share at all: not the owner, or the zone is gone. Distinct from
    /// `closed` — nothing here says anyone joined, and the UI must not claim so.
    case missing
}

/// All CloudKit access, shared by the app, the widget and the notification
/// service extension. Pairing is a zone-wide `CKShare`; each side writes only
/// records named after its own role, so the two phones can never conflict.
actor CloudSync: SyncBackend {
    static let shared = CloudSync()

    /// Not `private`: `CloudDiagnostics.swift` extends this actor from another file.
    let container: CKContainer
    /// The signed-in account, cached so `requirePairing` can verify it on every
    /// call without a network round trip each time. `readiness()` drops it.
    var cachedUserRecordName: (name: String, fetchedAt: Date)?
    static let accountCacheLifetime: TimeInterval = 5 * 60
    let log = Logger(subsystem: AppConfig.appGroupID, category: "CloudSync")

    enum RecordType {
        static let status = "Status"
        static let nudge = "Nudge"
        static let moment = "Moment"
        static let receipt = "Receipt"
        /// One per status change, alongside the overwritten `Status` — the
        /// durable history that a reinstall gets back.
        static let statusLog = "StatusLog"
    }

    enum Field {
        // Status. The human-readable parts are encrypted.
        static let emoji = "emoji"
        static let message = "message"
        static let displayName = "displayName"
        static let updatedAt = "updatedAt"
        /// CloudKit has no boolean type: Int64 (1/0), encrypted with the message.
        static let isCelebration = "isCelebration"

        // Nudge.
        static let count = "count"

        // Moment. `image`/`thumb`/`audio` are CKAssets, which CloudKit
        // encrypts by default — they must NOT go through `encryptedValues`.
        static let momentID = "momentID"
        static let kind = "kind"
        static let caption = "caption"
        static let senderName = "senderName"
        static let sentAt = "sentAt"
        static let image = "image"
        static let thumb = "thumb"
        // Voice memos only. `waveform` is a speech loudness envelope, so it
        // goes through `encryptedValues` like the caption.
        static let audio = "audio"
        static let duration = "duration"
        static let waveform = "waveform"

        // Receipt. A JSON blob of {momentID: seenAt}; which moments someone
        // read is behavioural, so it's encrypted like the captions. The status
        // receipt is two dates: when, and which status (`updatedAt`) it was.
        static let seenMap = "seenMap"
        static let statusSeenAt = "statusSeenAt"
        static let statusSeenFor = "statusSeenFor"
    }

    /// One subscription per record type — each wants a different payload.
    /// Not `private`: the notification extension routes on the push's
    /// `subscriptionID`; inferring from the sync delta misfires when another
    /// process consumed the delta first.
    enum SubscriptionID {
        /// A subscription's configuration can't be edited in place; a new ID
        /// forces every device onto the visible payload. The old one is deleted on sight.
        static let status = "status-alerts"
        static let legacySilentStatus = "status-changes"
        static let nudge = "nudge-alerts"
        static let moment = "moment-alerts"

        static let all = [status, legacySilentStatus, nudge, moment]
    }

    /// Server-composed fallback wording. Not `private`: `NotificationManager`
    /// matches on these to sweep a generic banner it is about to supersede.
    enum GenericAlert {
        static let status = "Updated their status"
        static let nudge = "Thinking of you 💭"
        static let moment = "Sent you something 📷"
    }

    /// `CKContainer(identifier:)` traps when the identifier isn't in the
    /// binary's entitlements — fail here rather than limp on. Injectable for tests.
    init(container: CKContainer? = nil) {
        self.container = container ?? CKContainer(identifier: AppConfig.cloudContainerID)
    }

    // MARK: - Account

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func readiness() async -> BackendReadiness {
        // The app calls this on every refresh and account change: re-check for real.
        cachedUserRecordName = nil
        do {
            let status = try await accountStatus()
            guard status == .available else {
                return .unavailable(SyncError.iCloudUnavailable(status).errorDescription ?? "")
            }
            // A *different* account also reports available; zone operations
            // then fail in ways that look like the partner unlinking.
            if let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
               await !isPairingAccount(pairing) {
                return .unavailable(SyncError.differentAccount.errorDescription ?? "")
            }
            return .ready
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .unavailable(message)
        }
    }

    func requireAvailableAccount() async throws {
        let status = try await container.accountStatus()
        guard status == .available else { throw SyncError.iCloudUnavailable(status) }
    }

    /// The signed-in account's user record name, or `nil` when it can't be
    /// fetched (offline, no account).
    func currentUserRecordName() async -> String? {
        if let cached = cachedUserRecordName,
           Date().timeIntervalSince(cached.fetchedAt) < Self.accountCacheLifetime {
            return cached.name
        }
        guard let name = try? await container.userRecordID().recordName else { return nil }
        cachedUserRecordName = (name, Date())
        return name
    }

    /// `false` only on positive proof of a different account. Errors and legacy
    /// pairings count as a match — destroying local state needs proof, not a network hiccup.
    func isPairingAccount(_ pairing: PairingInfo) async -> Bool {
        guard let expected = pairing.userRecordName,
              let current = await currentUserRecordName() else { return true }
        return current == expected
    }

    // MARK: - Helpers

    func requirePairing() async throws -> PairingInfo {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            throw SyncError.notPaired
        }
        // The owner's zone ID names *whoever is signed in*: under another
        // account every write would land in a stranger's zone. Cached lookup,
        // and only positive proof of a mismatch refuses (see `isPairingAccount`).
        guard await isPairingAccount(pairing) else { throw SyncError.differentAccount }
        return pairing
    }

    func database(for pairing: PairingInfo) -> CKDatabase {
        pairing.role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    func zoneID(for pairing: PairingInfo) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: pairing.zoneName, ownerName: pairing.zoneOwnerName)
    }

    func fetchRecord(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Merges whichever record changed into what we knew — the status record
    /// and its nudge counter often arrive separately.
    static func payload(from record: CKRecord?,
                                nudge: CKRecord?,
                                existing: StatusPayload?) -> StatusPayload? {
        guard record != nil || nudge != nil else { return nil }

        var payload = existing ?? StatusPayload(emoji: "💭",
                                                message: "",
                                                displayName: "",
                                                updatedAt: .distantPast,
                                                nudgeCount: 0,
                                                lastNudgeAt: nil)

        if let record {
            payload.emoji = record.encryptedValues[Field.emoji] as? String ?? payload.emoji
            payload.message = record.encryptedValues[Field.message] as? String ?? payload.message
            payload.displayName = record.encryptedValues[Field.displayName] as? String ?? payload.displayName
            // Whole seconds: local persistence is ISO-8601 (no fractional
            // seconds), and equality against stored copies — the announce
            // watermark, celebration replay guard, history dedup — must hold.
            let updated = record[Field.updatedAt] as? Date
                ?? record.modificationDate
                ?? payload.updatedAt
            payload.updatedAt = Date(timeIntervalSince1970: updated.timeIntervalSince1970.rounded(.down))
            // Fallback must be `false`, not the previous value — otherwise a
            // celebration would stick to the next status.
            payload.isCelebration =
                (record.encryptedValues[Field.isCelebration] as? Int).map { $0 != 0 } ?? false
        }

        if let nudge {
            payload.nudgeCount = nudge[Field.count] as? Int ?? payload.nudgeCount
            payload.lastNudgeAt = nudge[Field.sentAt] as? Date ?? payload.lastNudgeAt
        }

        return payload
    }

    static func firstSavedRecord(
        from result: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                      deleteResults: [CKRecord.ID: Result<Void, Error>])
    ) throws -> CKRecord? {
        for (_, saveResult) in result.saveResults {
            return try saveResult.get()
        }
        return nil
    }
}
