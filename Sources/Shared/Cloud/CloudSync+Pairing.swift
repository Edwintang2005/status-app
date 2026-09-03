import CloudKit
import Foundation
import os

// Pairing and the zone-wide share: create/accept/rejoin, the invite link
// lifecycle and the two-step close (CLAUDE.md invariant 9), zone recovery.
extension CloudSync {
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
            // A new pairing starts clean: nothing from a previous partner (an
            // unlink already wiped, but a refresh in flight at the time could
            // have refiled some of it since).
            SharedStore.shared.eraseLocalMedia()
            SharedStore.shared.pairing = info
            // A fresh invite re-arms the auto-close.
            SharedStore.shared.inviteClosed = false
        }
        try await bootstrapAfterPairing(displayName: displayName)
        return url
    }

    /// Gets the zone into a shared, joinable state. A reset deletes the zone and
    /// the server's view briefly disagrees afterwards; both recovery paths absorb that window.
    func zoneShare(displayName: String,
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

    func createZoneShare(displayName: String,
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
    func reopened(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
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
        guard share.publicPermission == .readWrite, let url = share.url else {
            return .closed(share.url)
        }
        return .open(url)
    }

    /// Owner side. Revokes link-based joining once the partner is in, so a forwarded
    /// link can't add a third person. Idempotent, but a two-step handshake: no
    /// single save converts a link-joined participant (an in-place role flip is
    /// silently ignored — close included — and close+add in one save applies
    /// the close but drops the add; both observed against the live service).
    /// So: close (which sweeps the public joiner), then re-add them as an
    /// *invited* private participant. They confirm by tapping the invite link
    /// once, which flips them accepted — the link itself stays closed.
    func lockPairing() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { throw SyncError.notPaired }

        let database = container.privateCloudDatabase
        let zoneID = self.zoneID(for: pairing)
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else { return }

        if share.publicPermission != .none {
            let publics = share.participants.filter { $0.role == .publicUser }
            // Resolve invite handles before anything is written — a failure
            // here must abort while the partner is still untouched.
            let invited = try await privateParticipants(matching: publics)

            share.publicPermission = .none
            _ = try await database.modifyRecords(saving: [share], deleting: [])

            if !invited.isEmpty {
                // From here the partner is off the share until the private seat is
                // confirmed. Any failure reopens the link: left closed, a retry would
                // see "already closed", report success, and the partner's next
                // refresh would wipe their history over a vanished zone.
                do {
                    try await promoteToPrivate(invited, zoneID: zoneID, in: database)
                } catch {
                    log.error("Promote failed after the close; reopening the invite link.")
                    await reopenInvite(zoneID: zoneID, in: database)
                    throw error
                }
            }
        }
        await MainActor.run { SharedStore.shared.inviteClosed = true }
    }

    /// The re-add half of the close handshake. Throws unless the partner is
    /// visibly on the share as a private participant afterwards.
    func promoteToPrivate(_ invited: [CKShare.Participant],
                          zoneID: CKRecordZone.ID,
                          in database: CKDatabase) async throws {
        guard let closed = try await existingZoneShare(in: database, zoneID: zoneID) else {
            throw SyncError.couldNotSecureShare("the share was unreadable after the close")
        }
        for participant in invited {
            participant.permission = .readWrite
            closed.addParticipant(participant)
        }
        _ = try await database.modifyRecords(saving: [closed], deleting: [])

        // Verify the invitation landed; pending is success here — the
        // partner's link tap is what flips it to accepted. Polled, since
        // an immediate refetch can trail the save.
        var confirmed: CKShare?
        var partnerInvited = false
        for attempt in 1...5 {
            confirmed = try await existingZoneShare(in: database, zoneID: zoneID)
            partnerInvited = confirmed?.participants.contains {
                $0.role != .owner && $0.role != .publicUser
            } ?? false
            if partnerInvited { break }
            log.notice("Private invitation not visible yet (attempt \(attempt) of 5).")
            try? await Task.sleep(for: .seconds(2))
        }
        guard partnerInvited else {
            let survivors = confirmed?.participants
                .filter { $0.role != .owner }
                .map { "role \($0.role.rawValue) status \($0.acceptanceStatus.rawValue)" }
                .joined(separator: ", ")
            throw SyncError.couldNotSecureShare(
                "the private invitation didn't stick — the server kept: "
                + ((survivors?.isEmpty ?? true) ? "no one but you" : survivors!)
                + "; the link was reopened")
        }
        log.notice("Invite closed; partner re-added as a private participant. Participants now: \(confirmed?.participants.count ?? 0).")
    }

    /// Best effort: puts the link back the way it was before a failed promote.
    func reopenInvite(zoneID: CKRecordZone.ID, in database: CKDatabase) async {
        guard let share = try? await existingZoneShare(in: database, zoneID: zoneID) else {
            log.error("Couldn't read the share to reopen the invite link.")
            return
        }
        share.publicPermission = .readWrite
        do {
            _ = try await database.modifyRecords(saving: [share], deleting: [])
        } catch {
            log.error("Couldn't reopen the invite link: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-accepting our own share — how a partner who is `pending` after the
    /// promote handshake (or on a fresh device) confirms their private seat.
    func reacceptShare(_ metadata: CKShare.Metadata) async throws {
        try await requireAvailableAccount()
        _ = try await container.accept(metadata)
    }

    /// Private-participant invite handles for the given public joiners. Public
    /// joiners have no email/phone `lookupInfo` (discoverability is gone since
    /// iOS 17), but the share exposes their `userRecordID`, which resolves too.
    /// Throws unless *every* one resolves: a partial swap must not start.
    func privateParticipants(
        matching publics: [CKShare.Participant]
    ) async throws -> [CKShare.Participant] {
        guard !publics.isEmpty else { return [] }
        let lookupInfos = publics.compactMap { participant in
            participant.userIdentity.lookupInfo
                ?? participant.userIdentity.userRecordID
                    .map { CKUserIdentity.LookupInfo(userRecordID: $0) }
        }
        guard lookupInfos.count == publics.count else {
            log.error("A public participant has no lookup info or user record ID; cannot promote safely.")
            throw SyncError.couldNotSecureShare("the partner's account couldn't be identified for promotion")
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
            throw SyncError.couldNotSecureShare("iCloud resolved \(fetched.count) of \(publics.count) participants")
        }
        return fetched
    }

    /// Closes the invite link once the partner's status record proves they're in —
    /// the link is a bearer token to the *entire* zone. Best-effort on purpose:
    /// a failure must not fail the refresh; the unset flag retries next time.
    func closeInviteIfPartnerJoined(_ pairing: PairingInfo) async {
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

    /// Settings' plain close: shuts the link only while nobody has come through
    /// it. With a link-joined partner on the share, closing evicts them — that is
    /// the promote handshake, which runs from Diagnostics only (invariant 9).
    func closeUnusedInvite() async throws {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { throw SyncError.notPaired }
        let database = container.privateCloudDatabase
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID(for: pairing)) else {
            return
        }
        guard !share.participants.contains(where: { $0.role != .owner }) else {
            throw SyncError.inviteInUse
        }
        if share.publicPermission != .none {
            share.publicPermission = .none
            _ = try await database.modifyRecords(saving: [share], deleting: [])
        }
        await MainActor.run { SharedStore.shared.inviteClosed = true }
    }

    /// Confirms a real person is on the share, then promote-and-close. The status
    /// record alone can be a leftover from a previous pairing — only the share's
    /// own participant list is proof, or a fresh invite gets killed unused.
    func lockIfPartnerOnShare(_ pairing: PairingInfo) async throws {
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

    /// Diagnostics maintenance: ejects link-joined (public) participants by
    /// closing the share — the documented sweep — then reopens it. Named
    /// participants survive and nobody's records are touched; the tool for a
    /// stray joiner on an open link. Returns a report line either way.
    func sweepPublicJoiners() async -> String {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { return "Only the owner can sweep the share." }
        let database = container.privateCloudDatabase
        let zoneID = self.zoneID(for: pairing)
        do {
            guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else {
                return "No share found."
            }
            let publicCount = share.participants.filter { $0.role == .publicUser }.count
            share.publicPermission = .none
            _ = try await database.modifyRecords(saving: [share], deleting: [])

            guard let closed = try await existingZoneShare(in: database, zoneID: zoneID) else {
                return "Share unreadable after the sweep — check Diagnostics before sharing the link."
            }
            closed.publicPermission = .readWrite
            _ = try await database.modifyRecords(saving: [closed], deleting: [])
            await MainActor.run { SharedStore.shared.inviteClosed = false }
            return "Swept \(publicCount) public joiner(s); link reopened. "
                + "Participants now: \(closed.participants.count)."
        } catch {
            return "Sweep failed: \(error.localizedDescription)"
        }
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
            // would fail every refresh from the first; leftover media to a
            // previous partner.
            for key in ["private", "shared"] {
                SharedStore.shared.setChangeToken(nil, for: key)
            }
            SharedStore.shared.eraseLocalMedia()
            SharedStore.shared.pairing = info
        }
        try await bootstrapAfterPairing(displayName: displayName)
    }

    /// The couple's zone as the server still knows it, when this device has no
    /// local pairing — a fresh install on a new phone. A shared-database hit
    /// means this account already accepted the share; a private-database hit
    /// (owner side) only counts with a share attached, since a bare leftover
    /// zone isn't a pairing. `nil` means an invite link is genuinely needed.
    func discoverExistingPairing() async -> (role: PairRole, zoneID: CKRecordZone.ID)? {
        guard await MainActor.run(body: { SharedStore.shared.pairing == nil }) else { return nil }
        guard (try? await accountStatus()) == .available else { return nil }

        if let zone = try? await container.sharedCloudDatabase.allRecordZones()
            .first(where: { $0.zoneID.zoneName == AppConfig.coupleZoneName }) {
            return (.participant, zone.zoneID)
        }
        if let zone = try? await container.privateCloudDatabase.allRecordZones()
            .first(where: { $0.zoneID.zoneName == AppConfig.coupleZoneName && $0.share != nil }) {
            return (.owner, zone.zoneID)
        }
        return nil
    }

    /// Recommits a pairing found by `discoverExistingPairing` — the account is
    /// already on the share (or owns the zone), so no invite link and no
    /// `CKShare.Metadata` are involved. The cleared tokens make the next
    /// refresh pull the whole zone, which is how the history comes back.
    func rejoin(role: PairRole, zoneID: CKRecordZone.ID, displayName: String) async throws {
        try await requireAvailableAccount()
        if role == .participant {
            try await waitForSharedZone(zoneID)
        }

        let info = PairingInfo(role: role,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date(),
                               userRecordName: await currentUserRecordName())
        await MainActor.run {
            for key in ["private", "shared"] {
                SharedStore.shared.setChangeToken(nil, for: key)
            }
            SharedStore.shared.pairing = info
        }
        try await bootstrapAfterPairing(displayName: displayName, rejoining: true)
    }

    /// Publish an opening status and register for change pushes, so the other
    /// side sees something the moment pairing completes. A rejoin (same pairing,
    /// new phone) keeps the status already on the server instead — announcing
    /// "just joined" over it would tell the partner something false.
    func bootstrapAfterPairing(displayName: String, rejoining: Bool = false) async throws {
        try? await registerSubscription()
        var existing: StatusPayload?
        if rejoining {
            _ = try? await refresh()
            existing = await MainActor.run { SharedStore.shared.snapshot.mine }
            if existing?.updatedAt == .distantPast { existing = nil }
        }
        if var renamed = existing {
            if renamed.displayName != displayName {
                renamed.displayName = displayName
                renamed.updatedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                try await publish(renamed, logged: false)
            }
        } else {
            try await publish(.initial(displayName: displayName))
        }
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
    func waitForSharedZone(_ zoneID: CKRecordZone.ID) async throws {
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
    func withZoneRecovery<T>(_ pairing: PairingInfo,
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
    func abandonMissingZone(_ pairing: PairingInfo) async throws {
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
    func existingZoneShare(in database: CKDatabase,
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
}
