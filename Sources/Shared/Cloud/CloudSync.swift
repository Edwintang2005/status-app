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
    /// The device is signed into a different iCloud account than the one the
    /// pairing was made under. The zone looks missing from here, but wiping
    /// local state over it would destroy a pairing that is actually intact.
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
            // Names the two causes the user can actually act on. The third —
            // the two devices running builds that talk to different CloudKit
            // environments, e.g. TestFlight against Xcode — looks identical
            // from here and is covered by "the same build".
            return "Couldn't open the shared space. Ask them to send a fresh "
                + "invite link, and check you're both on the same build of "
                + "\(AppConfig.appName)."
        case .linkEnded:
            // Deliberately doesn't assert why: from this device, the other
            // person unlinking and a zone that was never reachable look the
            // same, and blaming them for the second would be a guess.
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
    /// No share at all: not the owner, or the shared zone is gone. Distinct
    /// from `closed` on purpose — nothing about this says anyone joined, and
    /// the UI must not claim they did.
    case missing
}

/// All CloudKit access, shared by the app, the widget and the notification
/// service extension.
///
/// Pairing uses a **zone-wide `CKShare`**: whoever pairs first owns a custom
/// zone in their private database and shares the whole zone; the other side
/// accepts and sees that zone in their shared database. Each side writes only
/// records named after its own role, so the two phones can never conflict and
/// neither needs to learn the other's CloudKit user ID.
actor CloudSync: SyncBackend {
    static let shared = CloudSync()

    /// Not `private`: `CloudDiagnostics.swift` extends this actor from
    /// another file and needs the container and its database picker.
    let container: CKContainer
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "CloudSync")

    private enum RecordType {
        static let status = "Status"
        static let nudge = "Nudge"
        static let moment = "Moment"
    }

    private enum Field {
        // Status. The human-readable parts are encrypted; CloudKit's servers
        // never see them.
        static let emoji = "emoji"
        static let message = "message"
        static let displayName = "displayName"
        static let updatedAt = "updatedAt"
        /// CloudKit has no boolean type, so this is an Int64 (1/0). Encrypted
        /// alongside the message it belongs to rather than left in the clear
        /// with the timestamps.
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
        // Voice memos only. `waveform` is a loudness envelope of someone
        // speaking, so it's treated like the caption rather than like a
        // timestamp and goes through `encryptedValues`.
        static let audio = "audio"
        static let duration = "duration"
        static let waveform = "waveform"
    }

    /// One subscription per record type, because they want different payloads:
    /// a status change must stay silent, a nudge must be seen, and a moment
    /// must additionally wake the notification service extension.
    ///
    /// Not `private`: the notification service extension reads the incoming
    /// push's `subscriptionID` to decide whether it's enriching a nudge or a
    /// moment — inferring that from the sync delta misfires whenever another
    /// process consumed the delta first.
    enum SubscriptionID {
        /// "status-alerts", not the original "status-changes": the payload
        /// changed from silent to visible, and a subscription's configuration
        /// can't be edited in place — a new ID is what forces every device to
        /// pick up the new behaviour. The old one is deleted on sight.
        static let status = "status-alerts"
        static let legacySilentStatus = "status-changes"
        static let nudge = "nudge-alerts"
        static let moment = "moment-alerts"

        static let all = [status, legacySilentStatus, nudge, moment]
    }

    /// The server-composed wording each subscription shows when the service
    /// extension couldn't enrich it. Not `private`: `NotificationManager`
    /// matches on these to sweep a generic banner it is about to supersede
    /// with the real thing — and must match only its own event's wording.
    enum GenericAlert {
        static let status = "Updated their status"
        static let nudge = "Thinking of you 💭"
        static let moment = "Sent you something 📷"
    }

    /// `CKContainer(identifier:)` traps at launch when the identifier isn't in
    /// the running binary's entitlements, so an unsigned build — or one signed
    /// by a team without the iCloud capability — fails here rather than limping
    /// on. Injectable so tests can hand in their own container.
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
            // Available isn't enough once paired: a *different* account also
            // reports available, and every zone operation then fails in ways
            // that look like the partner unlinking.
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

    /// `false` only when this device can positively prove it is signed into a
    /// different iCloud account than the one the pairing was made under.
    /// Errors and legacy pairings (no stored record name) count as a match —
    /// destroying local state needs proof, not a network hiccup.
    private func isPairingAccount(_ pairing: PairingInfo) async -> Bool {
        guard let expected = pairing.userRecordName,
              let current = await currentUserRecordName() else { return true }
        return current == expected
    }

    // MARK: - Pairing

    /// Owner side. Creates the shared zone (if needed), shares it zone-wide, and
    /// returns the invite link to hand to the partner.
    ///
    /// The share is created with `publicPermission = .readWrite` so the partner
    /// can join from the link alone — no need to know their Apple Account
    /// address. `closeInviteIfPartnerJoined()` revokes that the moment they're
    /// in, and this reopens it for a genuinely new invite.
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
            // A fresh invite is an open invite: re-arm the auto-close so it
            // fires again for whoever joins with this link.
            SharedStore.shared.inviteClosed = false
        }
        try await bootstrapAfterPairing(displayName: displayName)
        return url
    }

    /// Gets the zone into a shared, joinable state.
    ///
    /// Both recovery paths exist for the same reason: a reset deletes the zone,
    /// and for a short window afterwards the server's view of it disagrees with
    /// what the client was just told. Rather than making the user discover that
    /// pressing the button twice works, absorb that window here.
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
            // A beat for the server to settle: the zone was recreated moments
            // ago, and asking again in the same breath returns the same answer.
            try? await Task.sleep(for: .seconds(1))

            // The save may have landed despite reporting failure.
            if let landed = try? await existingZoneShare(in: database, zoneID: zoneID) {
                log.notice("Share existed despite the error; using it.")
                return try await reopened(landed, in: database)
            }

            // Or the zone itself hadn't settled, in which case one more
            // creation — of the zone and then the share — is the whole fix.
            // Anything else is a real failure and has to reach the user: an
            // undeployed production schema must not be retried into silence.
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

    /// Reopens a share that has been closed to link-based joining.
    ///
    /// A share left over from a previous pairing — now that the link closes
    /// itself once someone joins — is very likely locked. Reachable when an
    /// unlink couldn't reach iCloud and the user took the "remove from this
    /// iPhone only" escape hatch: the zone and its closed share outlive the
    /// local reset. Handing back a URL nobody can join with would be a silent
    /// dead end.
    ///
    /// Any non-owner participants still on that share belong to the *previous*
    /// pairing, and since the auto-close promotes joiners to durable private
    /// participants, they'd otherwise keep read/write access to everything the
    /// new couple shares. They are removed before the link reopens. This is
    /// the one place in the app that removes anyone from a share, and it is
    /// only reachable from `createPairInvite` — a device that is currently
    /// paired never calls it, so a live partner cannot be swept up.
    private func reopened(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
        var share = share

        if share.participants.contains(where: { $0.role != .owner }) {
            // The participant list can only be edited while link-joining is
            // closed, so close first if a previous build left it open. (This
            // save also drops stale *public* joiners on its own.)
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

    /// Owner side. What the server currently says about the invite link.
    ///
    /// `createPairInvite` hands the URL back exactly once, so it used to live
    /// only as long as the screen that showed it — leave the pairing view, or
    /// relaunch, and the link was unrecoverable even though the share itself
    /// was still open and waiting. The share is the durable thing, so ask the
    /// server for it rather than trusting a cached copy that goes stale the
    /// moment the invite is closed from another device.
    func inviteState() async throws -> InviteState {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { return .missing }
        try await requireAvailableAccount()

        let database = container.privateCloudDatabase
        guard let share = try await existingZoneShare(in: database,
                                                      zoneID: zoneID(for: pairing)) else {
            return .missing
        }
        // A closed share still carries a `url`, and handing that out would be a
        // link that silently fails for whoever taps it.
        guard share.publicPermission == .readWrite, let url = share.url else { return .closed }
        return .open(url)
    }

    /// Owner side. Revokes link-based joining once the partner is in, so a
    /// forwarded or screenshotted link can't add a third person.
    ///
    /// Idempotent: an already-closed share is left untouched, and the local
    /// flag is set either way so `closeInviteIfPartnerJoined` stops looking.
    ///
    /// A URL-joiner is a *public* participant, and CloudKit's rules for those
    /// are strict: their role cannot be edited in place (verified on-device —
    /// the save is accepted and the role stays `publicUser`), `addParticipant`
    /// on an open share throws, and saving `publicPermission = .none` removes
    /// every public participant. The one documented path through — from
    /// CKShare.h itself — is a single atomic save that both closes the link
    /// and re-adds the same person as a properly fetched *private*
    /// participant: matching user identities merge, so the person carries
    /// over instead of being dropped. Atomicity is the safety property: the
    /// save either lands whole (partner private, link closed) or fails whole
    /// (partner untouched, link still open). There is no committed middle.
    func lockPairing() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { throw SyncError.notPaired }

        let database = container.privateCloudDatabase
        let zoneID = self.zoneID(for: pairing)
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else { return }

        if share.publicPermission != .none {
            let publics = share.participants.filter { $0.role == .publicUser }

            // Every public participant must come back as a private one in the
            // same save, so fetch their private-participant handles first —
            // any failure here aborts before anything is written.
            let refetched = try await privateParticipants(matching: publics)
            for participant in refetched {
                participant.permission = .readWrite
                share.addParticipant(participant)
            }
            share.publicPermission = .none
            _ = try await database.modifyRecords(saving: [share], deleting: [])

            // Trust nothing: ask the server what the share looks like now. If
            // the merge didn't preserve the partner, reopen the link at once —
            // their device can rejoin from the same URL — and report failure.
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

    /// The private-participant handles for the given (public) participants,
    /// fetched by user identity — the only participant objects
    /// `addParticipant` accepts. Throws unless *every* one resolves: a swap
    /// that would carry only some people over must not start.
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

    /// Closes the invite link as soon as there is proof the partner is in.
    ///
    /// The link is a bearer token: `publicPermission = .readWrite` means whoever
    /// holds the URL can join, and a joining device with no change token is
    /// handed the **entire zone** — every photo, drawing and memo ever sent, not
    /// just what happens next. Leaving that open until someone remembers a
    /// button in Settings is the wrong default for a forwarded screenshot, so
    /// the app closes it rather than the user.
    ///
    /// The proof is a `status-participant` record existing: only a share
    /// participant can write one, and pairing publishes it immediately. That
    /// costs no extra fetch — the refresh just read it — so the one round trip
    /// to revoke happens once per pairing, and never for an owner still waiting
    /// to be joined.
    ///
    /// Best-effort on purpose: a failure here must not fail the refresh that
    /// carried it. The flag stays unset, so the next refresh tries again.
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

    /// The shared core of auto-close and the diagnostics trigger: confirm a
    /// real person is on the share, then promote-and-close.
    ///
    /// The status record alone is not proof enough: after a local reset it
    /// can be a *leftover* from the previous pairing, and closing on its
    /// say-so kills a fresh invite before anyone has used it. Only the
    /// share's own participant list can confirm a person is actually in.
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

    /// Diagnostics-panel trigger: the same promote-and-close the background
    /// refresh attempts, run on demand so someone staring at a participant
    /// stuck on "public" can fire it by hand and watch the list change.
    /// Returns a line for the report when it fails; `nil` means it worked or
    /// there was nothing to do.
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
        // Accepting is not the same as having the zone. It appears in the shared
        // database asynchronously, and when it never appears at all this device
        // would otherwise sit there claiming to be paired while every read and
        // write failed with "Zone does not exist" — which is exactly what a
        // build talking to a different CloudKit environment than the owner's
        // looks like. Confirm before committing any local pairing state.
        try await waitForSharedZone(zoneID)

        let info = PairingInfo(role: .participant,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date(),
                               userRecordName: await currentUserRecordName())
        await MainActor.run {
            // Any change tokens still around belong to a previous pairing's
            // zone; handing one to a fetch against this zone fails every
            // refresh from the first.
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
        // Seed the nudge watermark from whatever is already on the server, so
        // pairing against an existing history doesn't fire a burst of stale
        // "thinking of you" notifications.
        await MainActor.run {
            _ = SharedStore.shared.mutate { $0.lastSeenPartnerNudgeCount = theirs?.nudgeCount ?? 0 }
        }
    }

    /// The zone's share, or `nil` when there isn't one.
    ///
    /// "Gone" is the answer here, not a failure. Right after a reset — which
    /// deletes the zone — `recordZones(for:)` can hand back metadata still
    /// pointing at the share record that belonged to the *deleted* zone, and
    /// fetching it then fails with "Zone does not exist". Letting that
    /// propagate is what put that alert in front of the user on the first
    /// press after a reset, and made a second press look like the fix: by then
    /// the stale reference was gone, so the share got created normally.
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
    ///
    /// `refresh()` has handled this since it was written; the write paths did
    /// not, so a status update against a missing zone surfaced the raw
    /// CloudKit text — "Error fetching record <CKRecordID: 0x…> from server:
    /// Zone does not exist" — and left the device still claiming to be paired,
    /// with no way forward but reinstalling.
    private func withZoneRecovery<T>(_ pairing: PairingInfo,
                                     _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CKError where Self.isAlreadyGone(error) {
            try await abandonMissingZone(pairing)
            throw SyncError.linkEnded
        }
    }

    /// Cuts this device loose from a zone that isn't there any more. Keeps the
    /// name, so pairing again is one step rather than two.
    ///
    /// Refuses when the device is signed into a *different* iCloud account:
    /// from there the pairing's zone is invisible even though it's intact, and
    /// wiping over that — then re-inviting from the original account, which
    /// sweeps the still-live partner off the share — is how one temporary
    /// account switch used to destroy the pairing and history on both phones.
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
                // Another device of ours wrote first; take the server copy and
                // reapply on top of it.
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

    /// Pulls everything that has changed in the shared zone since last time.
    ///
    /// Uses `CKFetchRecordZoneChangesOperation` rather than fetching known
    /// record names, for two reasons: moments are one record each with a UUID
    /// name, so there's nothing fixed to ask for; and a device with no stored
    /// token gets the **entire zone** back, which is how a reinstall recovers
    /// the full history. No `CKQuery`, so no Console indexes to configure.
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
            // The server aged our token out. Start clean and take the lot.
            // Token expiry is a *zone*-scoped error, so the operation reports
            // it rolled up inside `.partialFailure` — matching only the bare
            // code left the token in place and every refresh failing forever.
            log.notice("Change token expired, resyncing the whole zone.")
            previous = nil
            await MainActor.run { SharedStore.shared.setChangeToken(nil, for: tokenKey) }
            changes = try await fetchZoneChanges(zone: zone, in: database, since: nil)
        } catch let error as CKError where Self.isAlreadyGone(error) {
            // The other side unlinked, or the zone was never reachable. Without
            // this the app would keep showing their last status forever and
            // quietly retry a zone that isn't there.
            try await abandonMissingZone(pairing)
            throw SyncError.linkEnded
        }

        // Apply first, then advance the token. The other order has a window —
        // real for the notification extension, which the system kills on a
        // deadline — where the token is on disk but the records never made it
        // into local state; those records are then never delivered again.
        // This order's failure mode is merely applying the same delta twice,
        // which every path here tolerates.
        let result = await apply(changes, pairing: pairing, database: database)

        if let token = changes.token {
            let encoded = Self.encodeToken(token)
            await MainActor.run { SharedStore.shared.setChangeToken(encoded, for: tokenKey) }
        }

        await closeInviteIfPartnerJoined(pairing)
        return result
    }

    /// A reference type on purpose: the operation's per-record callbacks are
    /// escaping closures, and accumulating into a captured `var` struct is a
    /// data race as far as the compiler is concerned. CloudKit calls them
    /// serially, so a plain box is enough.
    private final class ZoneChanges: @unchecked Sendable {
        var records: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var token: CKServerChangeToken?
    }

    /// Assets are excluded via `desiredKeys` — this runs on every push, and a
    /// first sync could otherwise pull down every photo and recording ever
    /// sent. Media is fetched separately, and only for what's recent or
    /// actually being looked at.
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

        // Without the cancellation handler the operation runs to completion no
        // matter what: the widget's timeout and a cancelled `.task` both
        // "cancel" a task that then sits awaiting CloudKit anyway — the
        // widget's getTimeline stalls the full network duration and risks its
        // WidgetKit budget.
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
            case RecordType.moment:
                if let moment = Self.moment(from: record, mineRole: mineRole, theirsRole: theirsRole) {
                    moments.append(moment)
                }
            default:
                break
            }
        }

        // The partner deleting their own status record is how a participant
        // unlinks (they can't delete the owner's zone). Ignoring it left the
        // owner's app showing the ex's last status forever.
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
        // A delete and a recreation can share one delta (someone re-paired
        // into the same zone); the record that exists now wins.
        if theirStatus != nil { partnerErased = false }

        let store = SharedStore.shared
        let previousStatus = await MainActor.run { store.snapshot.theirs }

        // A status record and its nudge counter arrive independently, so fold
        // each into whatever the other side already knew.
        let mine = Self.payload(from: myStatus, nudge: myNudge,
                                existing: await MainActor.run { store.snapshot.mine })
        // Bound to a `let` before crossing into the main actor, like `arrived`
        // below: capturing the mutable flag is a data race under strict
        // concurrency.
        let erased = partnerErased
        let theirs = erased ? nil : Self.payload(from: theirStatus, nudge: theirNudge,
                                                 existing: previousStatus)

        await MainActor.run {
            _ = store.mutate(reloadWidgets: false) {
                // Checked *inside* the locked mutate: an unlink can land
                // between this refresh's fetch and its write-back, and
                // `clearPairing` clears the pairing key and the snapshot
                // under the same lock — so a nil pairing here means this
                // delta describes a relationship that just ended, and
                // writing it would resurrect the ex's status onto a wiped
                // snapshot.
                guard store.pairing != nil else { return }
                if let mine { $0.mine = mine }
                if erased {
                    $0.theirs = nil
                } else if let theirs {
                    $0.theirs = theirs
                }
                $0.isPaired = true
                $0.lastSyncedAt = Date()
            }
        }

        // Bound to a `let` before crossing into the main actor: capturing the
        // mutable array is a data race under strict concurrency.
        let arrived = moments.sorted { $0.sentAt < $1.sentAt }
        if arrived.isEmpty {
            if removedMoments {
                // A deletions-only delta (the partner unlinking is the big
                // one) still invalidates every snapshot field derived from
                // the index — without this the photo widget keeps pointing at
                // a moment whose files were just deleted.
                await MainActor.run { store.applyDerived(from: MomentIndex.shared.load()) }
            } else {
                SharedStore.reloadWidgets()
            }
        } else {
            await MainActor.run { store.record(arrived) }
            await downloadRecentMedia(for: arrived, pairing: pairing, in: database)
        }

        let newFromPartner = arrived.filter { !$0.fromMe }
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

    /// Writes the partner-visible nudge record. Because `Nudge` is its own
    /// record type, its subscription can carry a real alert while status
    /// changes stay silent. Returns `false` if the cooldown hasn't elapsed.
    @discardableResult
    func sendNudge() async throws -> Bool {
        let store = SharedStore.shared
        let now = Date()

        // Check and claim inside one `mutate`, under the cross-process lock:
        // the app's heart button and the lock-screen widget intent run in
        // different processes, and a check outside the lock let a simultaneous
        // tap on both send two nudges through one cooldown.
        let allowed = await MainActor.run { () -> Bool in
            var claimed = false
            _ = store.mutate(reloadWidgets: false) { snapshot in
                if let last = snapshot.lastNudgeSentAt,
                   now.timeIntervalSince(last) < AppConfig.nudgeCooldown {
                    return
                }
                // Claim the cooldown before the network call so a double-tap
                // can't slip a second nudge through while the first is in
                // flight.
                snapshot.lastNudgeSentAt = now
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
                    // Another device of ours (the widget intent, most likely)
                    // wrote first; refetch and increment on top of its count.
                    log.notice("Nudge conflict, retrying against server record.")
                    next = try await saveNudge(to: recordID, in: database, at: now)
                }

                await MainActor.run {
                    _ = store.mutate { snapshot in
                        snapshot.mine?.nudgeCount = next
                        snapshot.mine?.lastNudgeAt = now
                    }
                }
                return true
            }
        } catch {
            // Release the cooldown so a failed nudge can be retried immediately.
            await MainActor.run {
                _ = store.mutate(reloadWidgets: false) { $0.lastNudgeSentAt = nil }
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

    /// Moment ids come from the partner's device and end up interpolated into
    /// file paths inside the App Group. A modified client sending `../…` must
    /// not be able to write or delete outside `Moments/`.
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

    /// Three database subscriptions, filtered by record type.
    ///
    /// Only the status one is silent. Nudges and moments set `alertBody`, which
    /// makes CloudKit send a **visible, higher-priority** push — delivered by
    /// APNs whether or not the app is running, which is what makes them survive
    /// a force-quit. Moments additionally set `shouldSendMutableContent` so the
    /// notification service extension gets to enrich them first.
    ///
    /// The alert text is deliberately generic: CloudKit composes it server-side
    /// and cannot read `encryptedValues`, so personalising it would mean
    /// storing names in the clear. The service extension decrypts on-device and
    /// replaces the text with the real thing before it's shown.
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
            // Visible, so a status that scrolled past isn't gone: Notification
            // Centre keeps the history even when the app was never opened.
            // Deliberately no sound and no time-sensitivity — statuses change
            // many times a day, and this is a note on the lock screen, not an
            // interruption. The service extension replaces the generic text
            // with the real emoji and message, decrypted on-device.
            info.shouldSendMutableContent = true
            subscription.notificationInfo = info
            toSave.append(subscription)
        }
        // The pre-1.1 silent status subscription. Left in place it would
        // double-fire alongside the visible one above.
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

    /// Owner deletes the zone (which revokes the share); participant just stops
    /// listening. Either way local state is cleared.
    /// Ends the link from this side, cloud-first.
    ///
    /// What that means depends on who owns the zone, and the difference is not
    /// cosmetic:
    ///
    /// - **Owner**: the zone *is* the shared space, so deleting it removes
    ///   both people's statuses and every photo, drawing and recording either
    ///   of them sent. The other device finds out on its next refresh.
    /// - **Participant**: someone else's zone can't be deleted, so our own
    ///   records are deleted out of it first and then the share is left.
    ///   Skipping that first step would leave our last status and every photo
    ///   we ever sent sitting in their iCloud after we'd gone — which is
    ///   exactly what someone unlinking is trying to undo.
    func unpair() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else {
            return
        }
        let database = self.database(for: pairing)
        let zone = zoneID(for: pairing)

        // Best effort, deliberately: a stale subscription costs nothing, and
        // failing the unlink over one would be perverse.
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
            // "Gone" is only good news under the account that made the
            // pairing. Under a different one the zone merely *looks* gone,
            // and calling the unlink done would erase local state while
            // every photo and the open share sit intact in the other
            // account's iCloud — the exact lie this method must not tell.
            guard await isPairingAccount(pairing) else {
                throw SyncError.differentAccount
            }
            // They got there first. Nothing to delete is the outcome we wanted.
            log.notice("Shared zone already gone; unlink is a no-op.")
        }
    }

    /// Deletes every record in the zone that belongs to our own role. Uses a
    /// full change fetch rather than a query because moment records have UUID
    /// names — there is nothing to ask for by name, and no query index to rely
    /// on. Assets go with their records.
    private func deleteOwnRecords(role: PairRole,
                                  in zone: CKRecordZone.ID,
                                  database: CKDatabase) async throws {
        let changes = try await fetchZoneChanges(zone: zone, in: database, since: nil)
        let mine = changes.records.map(\.recordID).filter { id in
            let name = id.recordName
            return name == role.statusRecordName
                || name == role.nudgeRecordName
                || role.momentID(fromRecordName: name) != nil
        }
        guard !mine.isEmpty else { return }

        // Batched: one modify operation carrying hundreds of deletions is how
        // you get a `limitExceeded` instead of an unlink.
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
            // No share reference to delete — drop the whole zone from our own
            // shared database instead, which has the same effect for us.
            _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
            return
        }
        _ = try await database.modifyRecords(saving: [], deleting: [shareID])
    }

    /// Whether an error means "the thing you asked about isn't there any more",
    /// which for an unlink is success. Partial failures are unwrapped because a
    /// batch delete reports per-item errors rather than a top-level one.
    private static func isAlreadyGone(_ error: CKError) -> Bool {
        let gone: Set<CKError.Code> = [.unknownItem, .zoneNotFound, .userDeletedZone]
        if gone.contains(error.code) { return true }
        guard error.code == .partialFailure,
              let partials = error.partialErrorsByItemID?.values else { return false }
        // Every failure has to be a "gone" one; a real error hiding among them
        // still has to surface.
        let codes = partials.compactMap { ($0 as? CKError)?.code }
        return !codes.isEmpty && codes.allSatisfy(gone.contains)
    }

    /// Whether an error means the change token has expired — either bare, or
    /// wrapped in `.partialFailure` the way `CKFetchRecordZoneChangesOperation`
    /// reports zone-scoped errors.
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

    /// Merges whichever of the two records changed into what we already knew.
    /// The status record and its nudge counter are separate records now, so a
    /// change feed will often carry one without the other.
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
            // Absent on records written before this field existed, and on
            // every ordinary status, so the fallback is `false` rather than
            // whatever the last status happened to be — otherwise a
            // celebration would stick to the next thing they said.
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
