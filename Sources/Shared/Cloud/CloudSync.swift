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
    /// public after promotion — closing then would have removed them.
    case couldNotSecureShare
    /// Accepted an invite, but the shared zone never appeared.
    case shareUnavailable
    /// The shared zone is gone: the other person unlinked, and this device has
    /// just found out.
    case linkEnded
    /// Different iCloud account than the pairing's: the zone looks missing,
    /// but wiping local state would destroy an intact pairing.
    case differentAccount

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
        case .couldNotSecureShare:
            return "Couldn't close the invite link safely, so it was left "
                + "open. Nothing else changed — try again in a moment."
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
        }
    }
}

/// What the server says about the owner's invite link.
enum InviteState: Sendable, Equatable {
    /// Still joinable, carrying the link to hand over.
    case open(URL)
    /// The share is there but no longer accepts joins from the link — either
    /// the partner arrived or the owner closed it by hand.
    case closed
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
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "CloudSync")

    private enum RecordType {
        static let status = "Status"
        static let nudge = "Nudge"
        static let moment = "Moment"
        static let receipt = "Receipt"
    }

    private enum Field {
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
        // read is behavioural, so it's encrypted like the captions.
        static let seenMap = "seenMap"
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

    private func requireAvailableAccount() async throws {
        let status = try await container.accountStatus()
        guard status == .available else { throw SyncError.iCloudUnavailable(status) }
    }

    /// The signed-in account's user record name, or `nil` when it can't be
    /// fetched (offline, no account).
    private func currentUserRecordName() async -> String? {
        try? await container.userRecordID().recordName
    }

    /// `false` only on positive proof of a different account. Errors and legacy
    /// pairings count as a match — destroying local state needs proof, not a network hiccup.
    private func isPairingAccount(_ pairing: PairingInfo) async -> Bool {
        guard let expected = pairing.userRecordName,
              let current = await currentUserRecordName() else { return true }
        return current == expected
    }

    // MARK: - Pairing

    /// Owner side. Creates and shares the zone, returning the invite link.
    /// `publicPermission = .readWrite` lets the partner join from the link alone;
    /// `closeInviteIfPartnerJoined()` revokes that the moment they're in.
    func createPairInvite(displayName: String) async throws -> URL {
        try await requireAvailableAccount()

        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName,
                                     ownerName: CKCurrentUserDefaultName)

        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)],
                                                 deleting: [])

        let share = try await zoneShare(displayName: displayName, zoneID: zoneID, in: database)
        guard let url = share.url else { throw SyncError.shareURLMissing }

        let info = PairingInfo(role: .owner,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date(),
                               userRecordName: await currentUserRecordName())
        await MainActor.run {
            SharedStore.shared.pairing = info
            // A fresh invite re-arms the auto-close.
            SharedStore.shared.inviteClosed = false
        }
        try await bootstrapAfterPairing(displayName: displayName)
        return url
    }

    /// Gets the zone into a shared, joinable state. A reset deletes the zone and
    /// the server's view briefly disagrees afterwards; both recovery paths absorb that window.
    private func zoneShare(displayName: String,
                           zoneID: CKRecordZone.ID,
                           in database: CKDatabase) async throws -> CKShare {
        if let existing = try await existingZoneShare(in: database, zoneID: zoneID) {
            return try await reopened(existing, in: database)
        }

        do {
            return try await createZoneShare(displayName: displayName,
                                             zoneID: zoneID,
                                             in: database)
        } catch let error as CKError {
            log.error("Zone share save failed (CKError \(error.code.rawValue)); recovering.")
            // A beat for the server to settle after the zone was just recreated.
            try? await Task.sleep(for: .seconds(1))

            // The save may have landed despite reporting failure.
            if let landed = try? await existingZoneShare(in: database, zoneID: zoneID) {
                log.notice("Share existed despite the error; using it.")
                return try await reopened(landed, in: database)
            }

            // Otherwise recreate zone then share once. Anything else must reach
            // the user — an undeployed schema must not be retried into silence.
            guard Self.isAlreadyGone(error) else { throw error }
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)],
                                                     deleting: [])
            return try await createZoneShare(displayName: displayName,
                                             zoneID: zoneID,
                                             in: database)
        }
    }

    private func createZoneShare(displayName: String,
                                 zoneID: CKRecordZone.ID,
                                 in database: CKDatabase) async throws -> CKShare {
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "\(AppConfig.appName) — \(displayName)" as CKRecordValue
        share.publicPermission = .readWrite
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        return try Self.firstSavedRecord(from: result) as? CKShare ?? share
    }

    /// Reopens a share closed to link-based joining (a local-only reset leaves the
    /// zone and its closed share behind). The previous pairing's participants are
    /// removed first — they'd otherwise keep read/write access to the new couple's data.
    /// Only reachable from `createPairInvite`, never while paired, so a live partner can't be swept up.
    private func reopened(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
        var share = share

        if share.participants.contains(where: { $0.role != .owner }) {
            // Participants can only be edited while link-joining is closed, so
            // close first. (This save also drops stale *public* joiners.)
            if share.publicPermission != .none {
                share.publicPermission = .none
                let result = try await database.modifyRecords(saving: [share], deleting: [])
                share = try Self.firstSavedRecord(from: result) as? CKShare ?? share
            }
            let stale = share.participants.filter { $0.role != .owner }
            if !stale.isEmpty {
                log.notice("Removing \(stale.count) participant(s) from a previous pairing before re-inviting.")
                for participant in stale {
                    share.removeParticipant(participant)
                }
                let result = try await database.modifyRecords(saving: [share], deleting: [])
                share = try Self.firstSavedRecord(from: result) as? CKShare ?? share
            }
        }

        guard share.publicPermission != .readWrite else { return share }
        share.publicPermission = .readWrite
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        return try Self.firstSavedRecord(from: result) as? CKShare ?? share
    }

    /// Owner side. Asks the server for the invite link's state — the share is
    /// the durable thing; a cached URL goes stale the moment it's closed elsewhere.
    func inviteState() async throws -> InviteState {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { return .missing }
        try await requireAvailableAccount()

        let database = container.privateCloudDatabase
        guard let share = try await existingZoneShare(in: database,
                                                      zoneID: zoneID(for: pairing)) else {
            return .missing
        }
        // A closed share still carries a `url`; handing it out would silently fail.
        guard share.publicPermission == .readWrite, let url = share.url else { return .closed }
        return .open(url)
    }

    /// Owner side. Revokes link-based joining once the partner is in, so a forwarded
    /// link can't add a third person. Idempotent. Closing the link and re-adding the
    /// joiner as a fetched *private* participant must be one atomic save (per CKShare.h):
    /// it lands whole or fails whole — there is no committed middle.
    func lockPairing() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { throw SyncError.notPaired }

        let database = container.privateCloudDatabase
        let zoneID = self.zoneID(for: pairing)
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else { return }

        if share.publicPermission != .none {
            let publics = share.participants.filter { $0.role == .publicUser }

            // Fetch private-participant handles first — any failure aborts
            // before anything is written.
            let refetched = try await privateParticipants(matching: publics)
            for participant in refetched {
                participant.permission = .readWrite
                share.addParticipant(participant)
            }
            share.publicPermission = .none
            _ = try await database.modifyRecords(saving: [share], deleting: [])

            // Verify against the server; if the partner didn't survive the
            // merge, reopen the link at once and report failure.
            if !publics.isEmpty {
                let confirmed = try await existingZoneShare(in: database, zoneID: zoneID)
                let partnerIntact = confirmed?.participants.contains {
                    $0.role != .owner && $0.role != .publicUser
                        && $0.acceptanceStatus == .accepted
                } ?? false
                guard partnerIntact, let confirmed else {
                    log.error("Partner did not survive the close; reopening the invite link.")
                    if let confirmed {
                        confirmed.publicPermission = .readWrite
                        _ = try? await database.modifyRecords(saving: [confirmed], deleting: [])
                    }
                    throw SyncError.couldNotSecureShare
                }
                log.notice("Partner promoted to private participant; invite link closed. Participants now: \(confirmed.participants.count).")
            }
        }
        await MainActor.run { SharedStore.shared.inviteClosed = true }
    }

    /// Private-participant handles for the given public ones — the only objects
    /// `addParticipant` accepts. Throws unless *every* one resolves: a partial swap must not start.
    private func privateParticipants(
        matching publics: [CKShare.Participant]
    ) async throws -> [CKShare.Participant] {
        guard !publics.isEmpty else { return [] }
        let lookupInfos = publics.compactMap { $0.userIdentity.lookupInfo }
        guard lookupInfos.count == publics.count else {
            log.error("A public participant has no lookup info; cannot promote safely.")
            throw SyncError.couldNotSecureShare
        }

        let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: lookupInfos)
        final class Box: @unchecked Sendable { var participants: [CKShare.Participant] = [] }
        let box = Box()
        operation.perShareParticipantResultBlock = { _, result in
            if case .success(let participant) = result { box.participants.append(participant) }
        }

        let fetched: [CKShare.Participant] = try await withCheckedThrowingContinuation { continuation in
            operation.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success: continuation.resume(returning: box.participants)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            container.add(operation)
        }

        guard fetched.count == publics.count else {
            log.error("Resolved \(fetched.count) of \(publics.count) participants; refusing a partial promotion.")
            throw SyncError.couldNotSecureShare
        }
        return fetched
    }

    /// Closes the invite link once the partner's status record proves they're in —
    /// the link is a bearer token to the *entire* zone. Best-effort on purpose:
    /// a failure must not fail the refresh; the unset flag retries next time.
    private func closeInviteIfPartnerJoined(_ pairing: PairingInfo) async {
        guard pairing.role == .owner else { return }
        let shouldClose = await MainActor.run {
            !SharedStore.shared.inviteClosed && SharedStore.shared.snapshot.theirs != nil
        }
        guard shouldClose else { return }

        do {
            try await lockIfPartnerOnShare(pairing)
        } catch {
            log.error("Couldn't close the invite link: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Confirms a real person is on the share, then promote-and-close. The status
    /// record alone can be a leftover from a previous pairing — only the share's
    /// own participant list is proof, or a fresh invite gets killed unused.
    private func lockIfPartnerOnShare(_ pairing: PairingInfo) async throws {
        let database = container.privateCloudDatabase
        guard let share = try await existingZoneShare(in: database,
                                                      zoneID: zoneID(for: pairing)),
              share.participants.contains(where: {
                  $0.role != .owner && $0.acceptanceStatus == .accepted
              }) else {
            log.notice("Nobody on the share yet; leaving the invite open.")
            return
        }
        try await lockPairing()
        log.notice("Partner is on the share — invite link closed.")
    }

    /// Diagnostics-panel trigger for the same promote-and-close the refresh attempts.
    /// Returns a report line on failure; `nil` means it worked or there was nothing to do.
    func secureInviteIfPartnerJoined() async -> String? {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner,
              await MainActor.run(body: { !SharedStore.shared.inviteClosed }) else { return nil }
        do {
            try await lockIfPartnerOnShare(pairing)
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "secure invite: \(message)"
        }
    }

    /// Participant side. Called from the scene delegate when iOS hands us an
    /// accepted `CKShare.Metadata`.
    func acceptShare(_ metadata: CKShare.Metadata, displayName: String) async throws {
        try await requireAvailableAccount()
        _ = try await container.accept(metadata)

        let zoneID = metadata.share.recordID.zoneID
        // Accepting is not the same as having the zone: it appears asynchronously,
        // and may never (mismatched CloudKit environments). Confirm before
        // committing any local pairing state.
        try await waitForSharedZone(zoneID)

        let info = PairingInfo(role: .participant,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date(),
                               userRecordName: await currentUserRecordName())
        await MainActor.run {
            // Leftover change tokens belong to a previous pairing's zone and
            // would fail every refresh from the first.
            for key in ["private", "shared"] {
                SharedStore.shared.setChangeToken(nil, for: key)
            }
            SharedStore.shared.pairing = info
        }
        try await bootstrapAfterPairing(displayName: displayName)
    }

    /// Publish an opening status and register for change pushes, so the other
    /// side sees something the moment pairing completes.
    private func bootstrapAfterPairing(displayName: String) async throws {
        try? await registerSubscription()
        try await publish(.initial(displayName: displayName))
        let theirs = (try? await refresh())?.partnerStatus
        // Seed watermarks from the server so pairing against existing history
        // doesn't fire stale nudge notifications or mislabel the first push.
        await MainActor.run {
            _ = SharedStore.shared.mutate {
                $0.lastSeenPartnerNudgeCount = theirs?.nudgeCount ?? 0
                $0.lastAnnouncedPartnerStatusAt = theirs?.updatedAt
            }
        }
    }

    /// Blocks until the accepted zone is actually visible in the shared
    /// database, or gives up with something the user can act on.
    private func waitForSharedZone(_ zoneID: CKRecordZone.ID) async throws {
        let database = container.sharedCloudDatabase
        for attempt in 1...5 {
            if let zones = try? await database.recordZones(for: [zoneID]),
               case .success? = zones[zoneID] {
                return
            }
            log.notice("Shared zone not visible yet (attempt \(attempt) of 5).")
            try? await Task.sleep(for: .seconds(1))
        }
        log.error("Accepted a share but the zone never appeared: \(zoneID.zoneName, privacy: .public) owned by \(zoneID.ownerName, privacy: .public).")
        throw SyncError.shareUnavailable
    }

    /// Runs a shared-zone operation, turning "the zone isn't there" into the
    /// same self-unlink that a refresh performs.
    private func withZoneRecovery<T>(_ pairing: PairingInfo,
                                     _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CKError where Self.isAlreadyGone(error) {
            try await abandonMissingZone(pairing)
            throw SyncError.linkEnded
        }
    }

    /// Cuts this device loose from a missing zone, keeping the name. Refuses under
    /// a *different* iCloud account — the zone only looks gone there, and wiping
    /// would destroy an intact pairing on both phones.
    private func abandonMissingZone(_ pairing: PairingInfo) async throws {
        guard await isPairingAccount(pairing) else {
            log.notice("Zone unreachable, but this is a different iCloud account; keeping local state.")
            throw SyncError.differentAccount
        }
        log.notice("Shared zone is gone; unlinking this device.")
        await MainActor.run {
            SharedStore.shared.eraseLocalMedia()
            SharedStore.shared.clearPairing(keepingName: true)
        }
    }

    /// The zone's share, or `nil` when there isn't one. "Gone" is an answer, not a
    /// failure: right after a reset, stale metadata can point at the deleted zone's share.
    private func existingZoneShare(in database: CKDatabase,
                                   zoneID: CKRecordZone.ID) async throws -> CKShare? {
        do {
            let zones = try await database.recordZones(for: [zoneID])
            guard case .success(let zone)? = zones[zoneID],
                  let shareID = zone.share?.recordID else { return nil }
            let records = try await database.records(for: [shareID])
            guard case .success(let record)? = records[shareID] else { return nil }
            return record as? CKShare
        } catch let error as CKError where Self.isAlreadyGone(error) {
            log.notice("No existing zone share (CKError \(error.code.rawValue)).")
            return nil
        }
    }

    // MARK: - Status

    /// Writes this device's own status record. Only ever touches the record
    /// belonging to our own role, so the two phones can never conflict.
    func publish(_ payload: StatusPayload) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.statusRecordName,
                                   zoneID: zoneID(for: pairing))

        try await withZoneRecovery(pairing) {
            do {
                try await saveStatus(payload, to: recordID, in: database)
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Another device of ours wrote first; reapply on the server copy.
                log.notice("Status conflict, retrying against server record.")
                try await saveStatus(payload, to: recordID, in: database)
            }
        }

        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.mine = payload }
        }
    }

    private func saveStatus(_ payload: StatusPayload,
                            to recordID: CKRecord.ID,
                            in database: CKDatabase) async throws {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.status, recordID: recordID)
        record.encryptedValues[Field.emoji] = payload.emoji
        record.encryptedValues[Field.message] = payload.message
        record.encryptedValues[Field.displayName] = payload.displayName
        record.encryptedValues[Field.isCelebration] = payload.isCelebration ? 1 : 0
        record[Field.updatedAt] = payload.updatedAt as CKRecordValue
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
    }

    // MARK: - Refresh

    /// Pulls everything changed in the shared zone since last time. A change fetch,
    /// not queries: moments have UUID names, and a device with no stored token gets
    /// the entire zone back — which is how a reinstall recovers the full history.
    @discardableResult
    func refresh() async throws -> RefreshResult {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let zone = zoneID(for: pairing)
        let tokenKey = pairing.role == .owner ? "private" : "shared"

        var previous = await MainActor.run {
            Self.decodeToken(SharedStore.shared.changeToken(for: tokenKey))
        }

        let changes: ZoneChanges
        do {
            changes = try await fetchZoneChanges(zone: zone, in: database, since: previous)
        } catch let error as CKError where Self.isTokenExpired(error) {
            // Token expiry is zone-scoped, so it arrives wrapped in .partialFailure —
            // matching only the bare code left every refresh failing forever.
            log.notice("Change token expired, resyncing the whole zone.")
            previous = nil
            await MainActor.run { SharedStore.shared.setChangeToken(nil, for: tokenKey) }
            changes = try await fetchZoneChanges(zone: zone, in: database, since: nil)
        } catch let error as CKError where Self.isAlreadyGone(error) {
            // The other side unlinked, or the zone was never reachable.
            try await abandonMissingZone(pairing)
            throw SyncError.linkEnded
        }

        // Apply first, then advance the token: the other order can persist the token
        // without the records (the extension gets killed on a deadline), losing them
        // forever. Re-applying the same delta twice is tolerated everywhere here.
        let result = await apply(changes, pairing: pairing, database: database)

        if let token = changes.token {
            let encoded = Self.encodeToken(token)
            await MainActor.run { SharedStore.shared.setChangeToken(encoded, for: tokenKey) }
        }

        await closeInviteIfPartnerJoined(pairing)
        return result
    }

    /// A reference type on purpose: accumulating into a captured `var` struct is a
    /// data race to the compiler. CloudKit calls the blocks serially, so a box is enough.
    private final class ZoneChanges: @unchecked Sendable {
        var records: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var token: CKServerChangeToken?
    }

    /// Assets are excluded via `desiredKeys` — a first sync would otherwise pull
    /// every photo and recording ever sent. Media is fetched separately, on demand.
    private func fetchZoneChanges(zone: CKRecordZone.ID,
                                  in database: CKDatabase,
                                  since previous: CKServerChangeToken?) async throws -> ZoneChanges {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: previous,
            resultsLimit: nil,
            desiredKeys: [
                Field.emoji, Field.message, Field.displayName, Field.updatedAt,
                Field.isCelebration,
                Field.count,
                Field.momentID, Field.kind, Field.caption, Field.senderName, Field.sentAt,
                Field.duration, Field.waveform,
                Field.seenMap,
            ]
        )

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone],
            configurationsByRecordZoneID: [zone: configuration]
        )
        operation.fetchAllChanges = true

        let changes = ZoneChanges()
        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result { changes.records.append(record) }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            changes.deletedIDs.append(recordID)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            if case .success(let value) = result { changes.token = value.serverChangeToken }
        }

        // Without the cancellation handler the operation runs to completion regardless,
        // stalling the widget's getTimeline for the full network duration.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success: continuation.resume(returning: changes)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// Folds a batch of changed records into local state.
    private func apply(_ changes: ZoneChanges,
                       pairing: PairingInfo,
                       database: CKDatabase) async -> RefreshResult {
        let mineRole = pairing.role
        let theirsRole = pairing.role.other

        var myStatus: CKRecord?
        var theirStatus: CKRecord?
        var myNudge: CKRecord?
        var theirNudge: CKRecord?
        var theirReceipts: CKRecord?
        var moments: [Moment] = []

        for record in changes.records {
            let name = record.recordID.recordName
            switch record.recordType {
            case RecordType.status:
                if name == mineRole.statusRecordName { myStatus = record }
                if name == theirsRole.statusRecordName { theirStatus = record }
            case RecordType.nudge:
                if name == mineRole.nudgeRecordName { myNudge = record }
                if name == theirsRole.nudgeRecordName { theirNudge = record }
            case RecordType.receipt:
                if name == theirsRole.receiptRecordName { theirReceipts = record }
            case RecordType.moment:
                if let moment = Self.moment(from: record, mineRole: mineRole, theirsRole: theirsRole) {
                    moments.append(moment)
                }
            default:
                break
            }
        }

        // Captured before the insert below, so "new" can mean "not already
        // stored" — a full resync re-delivers the entire history, and reporting
        // it all as new re-announced already-seen moments.
        let alreadyKnown = MomentIndex.shared.knownIDs()

        // The partner deleting their own status record is how a participant
        // unlinks (they can't delete the owner's zone). Must not be ignored.
        var partnerErased = false
        var removedMoments = false
        for recordID in changes.deletedIDs {
            let name = recordID.recordName
            if name == theirsRole.statusRecordName { partnerErased = true }
            if let id = mineRole.momentID(fromRecordName: name)
                ?? theirsRole.momentID(fromRecordName: name),
               Self.isSafeMomentID(id) {
                MomentIndex.shared.remove(id: id)
                MomentStore.shared.delete(id: id)
                removedMoments = true
            }
        }
        // A delete and a recreation can share one delta; the record that exists now wins.
        if theirStatus != nil { partnerErased = false }

        let store = SharedStore.shared
        let previousStatus = await MainActor.run { store.snapshot.theirs }

        // A status record and its nudge counter arrive independently; fold
        // each into what was already known.
        let mine = Self.payload(from: myStatus, nudge: myNudge,
                                existing: await MainActor.run { store.snapshot.mine })
        // Bound to a `let` before crossing actors: capturing the mutable flag
        // is a data race under strict concurrency.
        let erased = partnerErased
        let theirs = erased ? nil : Self.payload(from: theirStatus, nudge: theirNudge,
                                                 existing: previousStatus)

        await MainActor.run {
            _ = store.mutate(reloadWidgets: false) {
                // Checked *inside* the locked mutate: an unlink can land mid-refresh,
                // and writing this delta would resurrect the ex's status onto a wiped snapshot.
                guard store.pairing != nil else { return }
                if let mine {
                    // A status set offline is newer than the server copy; adopting the
                    // server's silently reverted it. Keep the newer local text and take
                    // only the server-owned nudge counter.
                    if mine.updatedAt >= ($0.mine?.updatedAt ?? .distantPast) {
                        $0.mine = mine
                    } else {
                        $0.mine?.nudgeCount = mine.nudgeCount
                        $0.mine?.lastNudgeAt = mine.lastNudgeAt
                    }
                }
                if erased {
                    $0.theirs = nil
                } else if let theirs {
                    $0.theirs = theirs
                }
                $0.isPaired = true
                $0.lastSyncedAt = Date()
            }
        }

        // Status history rides the refresh, gated on the status *record* changing
        // (not a nudge-only delta); the log itself dedups by (fromMe, updatedAt).
        if let theirs, theirStatus != nil, !erased {
            StatusHistoryLog.shared.record(theirs, fromMe: false)
        }
        if let mine, myStatus != nil {
            // Own statuses set on this device are logged at set time; this
            // catches ones written by another device on the same account.
            StatusHistoryLog.shared.record(mine, fromMe: true)
        }

        if let theirReceipts {
            MomentIndex.shared.applyPartnerReceipts(Self.receiptMap(from: theirReceipts))
        }

        // Bound to a `let` before crossing actors: capturing the mutable array is a data race.
        let arrived = moments.sorted { $0.sentAt < $1.sentAt }
        if arrived.isEmpty {
            if removedMoments {
                // A deletions-only delta still invalidates snapshot fields derived from
                // the index — otherwise the photo widget points at deleted files.
                await MainActor.run { store.applyDerived(from: MomentIndex.shared.load()) }
            } else {
                SharedStore.reloadWidgets()
            }
        } else {
            await MainActor.run { store.record(arrived) }
            await downloadRecentMedia(for: arrived, pairing: pairing, in: database)
        }

        let newFromPartner = arrived.filter { !$0.fromMe && !alreadyKnown.contains($0.id) }
        return RefreshResult(partnerStatus: partnerErased ? nil : (theirs ?? previousStatus),
                             newPartnerMoments: newFromPartner)
    }

    /// Only the newest few, so a first sync after reinstall doesn't pull down
    /// hundreds of photos and recordings at once. The rest arrive on demand.
    private func downloadRecentMedia(for moments: [Moment],
                                     pairing: PairingInfo,
                                     in database: CKDatabase) async {
        let recent = moments.sorted { $0.sentAt > $1.sentAt }.prefix(10)
        for moment in recent where !MomentStore.shared.hasMedia(for: moment) {
            try? await downloadMedia(for: moment, pairing: pairing, in: database)
        }
        SharedStore.reloadWidgets()
    }

    // MARK: - Nudges

    /// Writes the partner-visible nudge record. Its own record type, so its
    /// subscription can carry a real alert. Returns `false` if the cooldown hasn't elapsed.
    @discardableResult
    func sendNudge() async throws -> Bool {
        let store = SharedStore.shared
        let now = Date()

        // Check and claim inside one `mutate` under the cross-process lock: the
        // app and the widget intent run in different processes, and an unlocked
        // check let two nudges through one cooldown.
        let allowed = await MainActor.run { () -> Bool in
            var claimed = false
            _ = store.mutate(reloadWidgets: false) { snapshot in
                if let last = snapshot.lastNudgeSentAt,
                   now.timeIntervalSince(last) < AppConfig.nudgeCooldown {
                    return
                }
                // Claim the cooldown before the network call so a double-tap
                // can't slip a second nudge through mid-flight.
                snapshot.lastNudgeSentAt = now
                // A retry is underway; the failure notice has done its job.
                snapshot.lastNudgeFailedAt = nil
                claimed = true
            }
            return claimed
        }
        guard allowed else { return false }

        do {
            let pairing = try await requirePairing()
            let database = self.database(for: pairing)
            let recordID = CKRecord.ID(recordName: pairing.role.nudgeRecordName,
                                       zoneID: zoneID(for: pairing))

            return try await withZoneRecovery(pairing) {
                let next: Int
                do {
                    next = try await saveNudge(to: recordID, in: database, at: now)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    // Another device of ours wrote first; refetch and increment on top.
                    log.notice("Nudge conflict, retrying against server record.")
                    next = try await saveNudge(to: recordID, in: database, at: now)
                }

                await MainActor.run {
                    _ = store.mutate { snapshot in
                        snapshot.mine?.nudgeCount = next
                        snapshot.mine?.lastNudgeAt = now
                        snapshot.lastNudgeFailedAt = nil
                    }
                }
                return true
            }
        } catch {
            // Release the cooldown for immediate retry and record the failure —
            // the lock-screen widget has no other way to show an offline tap
            // didn't send. Only if our own claim is still standing: another
            // process may have claimed (and sent) since, and clearing that
            // live cooldown would let a second nudge straight through.
            await MainActor.run {
                _ = store.mutate { snapshot in
                    guard snapshot.lastNudgeSentAt == now else { return }
                    snapshot.lastNudgeSentAt = nil
                    snapshot.lastNudgeFailedAt = Date()
                }
            }
            throw error
        }
    }

    /// One fetch-increment-save of the nudge record. Returns the new count.
    private func saveNudge(to recordID: CKRecord.ID,
                           in database: CKDatabase,
                           at now: Date) async throws -> Int {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.nudge, recordID: recordID)
        let next = (record[Field.count] as? Int ?? 0) + 1
        record[Field.count] = next as CKRecordValue
        record[Field.sentAt] = now as CKRecordValue
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
        return next
    }

    // MARK: - Moments

    /// Writes a new moment record. One record per moment, kept indefinitely —
    /// that's what makes the history durable and recoverable.
    func send(_ moment: Moment) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)

        let recordID = CKRecord.ID(recordName: pairing.role.momentRecordName(id: moment.id),
                                   zoneID: zoneID(for: pairing))

        let record = CKRecord(recordType: RecordType.moment, recordID: recordID)
        record[Field.momentID] = moment.id as CKRecordValue
        record[Field.kind] = moment.kind.rawValue as CKRecordValue
        record[Field.sentAt] = moment.sentAt as CKRecordValue
        record.encryptedValues[Field.caption] = moment.caption
        record.encryptedValues[Field.senderName] = moment.senderName

        let store = MomentStore.shared
        if moment.isVoice {
            guard let audioURL = store.audioURL(for: moment.id),
                  FileManager.default.fileExists(atPath: audioURL.path) else {
                throw MomentStoreError.audioMissing
            }
            record[Field.audio] = CKAsset(fileURL: audioURL)
            record[Field.duration] = moment.duration as CKRecordValue
            record.encryptedValues[Field.waveform] = moment.waveform
        } else {
            guard let fullURL = store.imageURL(for: moment.id),
                  let thumbURL = store.thumbURL(for: moment.id) else {
                throw MomentStoreError.containerUnavailable
            }
            record[Field.image] = CKAsset(fileURL: fullURL)
            record[Field.thumb] = CKAsset(fileURL: thumbURL)
        }

        try await withZoneRecovery(pairing) {
            _ = try await database.modifyRecords(saving: [record],
                                                 deleting: [],
                                                 savePolicy: .allKeys)
        }
    }

    // MARK: - Read receipts

    /// Writes this device's seen-map, overwriting the whole record. An empty
    /// map is a retraction — receipts were turned off.
    func publishReceipts(_ seen: [String: Date]) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        let recordID = CKRecord.ID(recordName: pairing.role.receiptRecordName,
                                   zoneID: zoneID(for: pairing))

        try await withZoneRecovery(pairing) {
            do {
                try await saveReceipts(seen, to: recordID, in: database)
            } catch let error as CKError where error.code == .serverRecordChanged {
                log.notice("Receipt conflict, retrying against server record.")
                try await saveReceipts(seen, to: recordID, in: database)
            }
        }
    }

    private func saveReceipts(_ seen: [String: Date],
                              to recordID: CKRecord.ID,
                              in database: CKDatabase) async throws {
        let record = try await fetchRecord(recordID, in: database)
            ?? CKRecord(recordType: RecordType.receipt, recordID: recordID)
        // 0 encodes "seen, time unknown" (.distantPast) — see Moment.seenAt.
        let raw = seen.mapValues { $0 == .distantPast ? 0 : $0.timeIntervalSince1970 }
        record.encryptedValues[Field.seenMap] = try JSONEncoder().encode(raw)
        record[Field.updatedAt] = Date() as CKRecordValue
        _ = try await database.modifyRecords(saving: [record],
                                             deleting: [],
                                             savePolicy: .changedKeys)
    }

    private static func receiptMap(from record: CKRecord) -> [String: Date] {
        guard let data = record.encryptedValues[Field.seenMap] as? Data,
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return raw.reduce(into: [:]) { result, item in
            guard isSafeMomentID(item.key) else { return }
            result[item.key] = item.value <= 0 ? .distantPast : Date(timeIntervalSince1970: item.value)
        }
    }

    /// Pulls the media file(s) for one history entry that isn't cached locally.
    /// Called by the gallery when you scroll back past the cache window.
    func fetchMedia(for moment: Moment) async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)
        try await downloadMedia(for: moment, pairing: pairing, in: database)
    }

    private func downloadMedia(for moment: Moment,
                               pairing: PairingInfo,
                               in database: CKDatabase) async throws {
        let role = moment.fromMe ? pairing.role : pairing.role.other
        let recordID = CKRecord.ID(recordName: role.momentRecordName(id: moment.id),
                                   zoneID: zoneID(for: pairing))
        guard let record = try await fetchRecord(recordID, in: database) else { return }

        let store = MomentStore.shared
        if moment.isVoice {
            try Self.copyAsset(record[Field.audio] as? CKAsset, to: store.audioURL(for: moment.id))
        } else {
            try Self.copyAsset(record[Field.image] as? CKAsset, to: store.imageURL(for: moment.id))
            try Self.copyAsset(record[Field.thumb] as? CKAsset, to: store.thumbURL(for: moment.id))
        }
    }

    private static func moment(from record: CKRecord,
                               mineRole: PairRole,
                               theirsRole: PairRole) -> Moment? {
        let name = record.recordID.recordName
        let fromMe: Bool
        if mineRole.momentID(fromRecordName: name) != nil {
            fromMe = true
        } else if theirsRole.momentID(fromRecordName: name) != nil {
            fromMe = false
        } else {
            return nil
        }

        guard let id = record[Field.momentID] as? String,
              isSafeMomentID(id),
              let kindRaw = record[Field.kind] as? String,
              let kind = Moment.Kind(rawValue: kindRaw) else { return nil }

        return Moment(
            id: id,
            kind: kind,
            caption: record.encryptedValues[Field.caption] as? String ?? "",
            senderName: record.encryptedValues[Field.senderName] as? String ?? "",
            sentAt: record[Field.sentAt] as? Date ?? record.modificationDate ?? Date(),
            fromMe: fromMe,
            duration: record[Field.duration] as? Double ?? 0,
            waveform: record.encryptedValues[Field.waveform] as? [Double] ?? []
        )
    }

    /// Moment ids come from the partner's device and are interpolated into App
    /// Group file paths; a modified client sending `../…` must not escape `Moments/`.
    private static func isSafeMomentID(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= 64
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("..")
            && id != "."
    }

    private static func copyAsset(_ asset: CKAsset?, to destination: URL?) throws {
        guard let source = asset?.fileURL, let destination else { return }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeToken(_ data: Data?) -> CKServerChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    // MARK: - Push subscriptions

    /// Three database subscriptions filtered by record type. `alertBody` makes a
    /// push visible and survive force-quit. The text stays generic because CloudKit
    /// composes it server-side and cannot read `encryptedValues`; the service
    /// extension replaces it with the decrypted content on-device.
    func registerSubscription() async throws {
        let pairing = try await requirePairing()
        let database = self.database(for: pairing)

        let existing = (try? await database.allSubscriptions()) ?? []
        let existingIDs = Set(existing.map(\.subscriptionID))

        var toSave: [CKSubscription] = []

        if !existingIDs.contains(SubscriptionID.status) {
            let subscription = CKDatabaseSubscription(subscriptionID: SubscriptionID.status)
            subscription.recordType = RecordType.status
            let info = CKSubscription.NotificationInfo()
            info.title = AppConfig.appName
            info.alertBody = GenericAlert.status
            // Visible so Notification Centre keeps status history, but deliberately
            // no sound or time-sensitivity — a note, not an interruption.
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }
        // The legacy silent status subscription would double-fire alongside the visible one.
        let toDelete = existingIDs.contains(SubscriptionID.legacySilentStatus)
            ? [SubscriptionID.legacySilentStatus]
            : []

        if !existingIDs.contains(SubscriptionID.nudge) {
            let subscription = CKDatabaseSubscription(subscriptionID: SubscriptionID.nudge)
            subscription.recordType = RecordType.nudge
            let info = CKSubscription.NotificationInfo()
            info.title = AppConfig.appName
            info.alertBody = GenericAlert.nudge
            info.soundName = "default"
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }

        if !existingIDs.contains(SubscriptionID.moment) {
            let subscription = CKDatabaseSubscription(subscriptionID: SubscriptionID.moment)
            subscription.recordType = RecordType.moment
            let info = CKSubscription.NotificationInfo()
            info.title = AppConfig.appName
            info.alertBody = GenericAlert.moment
            info.soundName = "default"
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }

        guard !toSave.isEmpty || !toDelete.isEmpty else { return }

        do {
            _ = try await database.modifySubscriptions(saving: toSave, deleting: toDelete)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            log.notice("Subscriptions already registered.")
        }
    }

    // MARK: - Unpairing

    /// Ends the link from this side, cloud-first. Owner: deletes the zone, removing
    /// everything for both people. Participant: our own records must be deleted
    /// *before* leaving the share, or they'd sit in the ex's iCloud after we'd gone.
    func unpair() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            return
        }
        let database = self.database(for: pairing)
        let zone = zoneID(for: pairing)

        // Best effort: failing the unlink over a stale subscription would be perverse.
        _ = try? await database.modifySubscriptions(saving: [], deleting: SubscriptionID.all)

        do {
            switch pairing.role {
            case .owner:
                _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
            case .participant:
                try await deleteOwnRecords(role: pairing.role, in: zone, database: database)
                try await leaveShare(zone: zone, database: database)
            }
        } catch let error as CKError where Self.isAlreadyGone(error) {
            // "Gone" is only good news under the pairing's account; under a different
            // one the zone merely *looks* gone while the data sits intact.
            guard await isPairingAccount(pairing) else {
                throw SyncError.differentAccount
            }
            // They got there first. Nothing to delete is the outcome we wanted.
            log.notice("Shared zone already gone; unlink is a no-op.")
        }
    }

    /// Deletes every record belonging to our own role, via a full change fetch —
    /// moment records have UUID names, so there's nothing to query by name.
    private func deleteOwnRecords(role: PairRole,
                                  in zone: CKRecordZone.ID,
                                  database: CKDatabase) async throws {
        let changes = try await fetchZoneChanges(zone: zone, in: database, since: nil)
        let mine = changes.records.map(\.recordID).filter { id in
            let name = id.recordName
            return name == role.statusRecordName
                || name == role.nudgeRecordName
                || name == role.receiptRecordName
                || role.momentID(fromRecordName: name) != nil
        }
        guard !mine.isEmpty else { return }

        // Batched: hundreds of deletions in one modify is a `limitExceeded`.
        for start in stride(from: 0, to: mine.count, by: 200) {
            let batch = Array(mine[start..<min(start + 200, mine.count)])
            _ = try await database.modifyRecords(saving: [], deleting: batch)
        }
        log.notice("Deleted \(mine.count) of our own records before leaving the share.")
    }

    /// Removes this account from the share, which is what makes the zone
    /// disappear from our shared database.
    private func leaveShare(zone: CKRecordZone.ID, database: CKDatabase) async throws {
        let zones = try await database.recordZones(for: [zone])
        guard case .success(let record)? = zones[zone],
              let shareID = record.share?.recordID else {
            // No share reference — drop the zone from our shared database instead.
            _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
            return
        }
        _ = try await database.modifyRecords(saving: [], deleting: [shareID])
    }

    /// Whether an error means "it isn't there any more". Partial failures are
    /// unwrapped because a batch delete reports per-item errors.
    private static func isAlreadyGone(_ error: CKError) -> Bool {
        let gone: Set<CKError.Code> = [.unknownItem, .zoneNotFound, .userDeletedZone]
        if gone.contains(error.code) { return true }
        guard error.code == .partialFailure,
              let partials = error.partialErrorsByItemID?.values else { return false }
        // Every failure must be a "gone" one; a real error must still surface.
        let codes = partials.compactMap { ($0 as? CKError)?.code }
        return !codes.isEmpty && codes.allSatisfy(gone.contains)
    }

    /// Token expiry arrives either bare or wrapped in `.partialFailure` (zone-scoped).
    private static func isTokenExpired(_ error: CKError) -> Bool {
        if error.code == .changeTokenExpired { return true }
        guard error.code == .partialFailure,
              let partials = error.partialErrorsByItemID?.values else { return false }
        return partials.contains { ($0 as? CKError)?.code == .changeTokenExpired }
    }

    // MARK: - Helpers

    private func requirePairing() async throws -> PairingInfo {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            throw SyncError.notPaired
        }
        return pairing
    }

    func database(for pairing: PairingInfo) -> CKDatabase {
        pairing.role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for pairing: PairingInfo) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: pairing.zoneName, ownerName: pairing.zoneOwnerName)
    }

    private func fetchRecord(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Merges whichever record changed into what we knew — the status record
    /// and its nudge counter often arrive separately.
    private static func payload(from record: CKRecord?,
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
            payload.updatedAt = record[Field.updatedAt] as? Date
                ?? record.modificationDate
                ?? payload.updatedAt
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

    private static func firstSavedRecord(
        from result: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                      deleteResults: [CKRecord.ID: Result<Void, Error>])
    ) throws -> CKRecord? {
        for (_, saveResult) in result.saveResults {
            return try saveResult.get()
        }
        return nil
    }
}
