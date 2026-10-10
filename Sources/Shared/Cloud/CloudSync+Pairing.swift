import CloudKit
import Foundation
import os

// Pairing and the zone-wide share: create/accept/rejoin, the invite link
// lifecycle and the two-step close (CLAUDE.md invariant 9), zone recovery.
extension CloudSync {
    /// Owner side. Creates and shares the zone, returning the invite link.
    /// `publicPermission = .readWrite` lets the partner join from the link alone;
    /// it stays open until closed by hand (invariant 9).
    /// A leftover zone (a new phone, "Remove from this iPhone only") that has
    /// someone on its share or any records in it is refused with `existingPairing`
    /// — reusing it would evict them and hand the next joiner the whole history.
    /// `replacingExisting`, after the user confirms, deletes that zone first.
    func createPairInvite(displayName: String, replacingExisting: Bool = false) async throws -> URL {
        try await requireAvailableAccount()

        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName,
                                     ownerName: CKCurrentUserDefaultName)

        if let leftover = try await leftoverZone(zoneID, in: database) {
            let someoneOnIt = leftover.share.map { SharePosture($0).memberCount } ?? 0 > 0
            // Confirmed, any leftover goes: a share read as empty may be a stale view.
            if someoneOnIt || leftover.hasRecords || replacingExisting {
                guard replacingExisting else { throw SyncError.existingPairing(someoneOnIt: someoneOnIt) }
                try await deleteLeftoverZone(zoneID, in: database)
            }
        }

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
            // have refiled some of it since), and no cursor into the old zone.
            SharedStore.shared.clearChangeTokens()
            SharedStore.shared.eraseLocalMedia()
            SharedStore.shared.lastPairing = nil
            SharedStore.shared.pairing = info
            // A fresh invite is open until closed by hand.
            SharedStore.shared.inviteClosed = false
            SharedStore.shared.closeLinkPromptDismissed = false
        }
        try await bootstrapAfterPairing(displayName: displayName)
        return url
    }

    /// What this account's couple zone already holds, or `nil` when there is no
    /// zone. Fails closed: a lookup that can't answer throws, never reads as empty.
    /// "Gone" arrives thrown (bare or per-item in `.partialFailure`) or per item.
    func leftoverZone(_ zoneID: CKRecordZone.ID,
                      in database: CKDatabase) async throws -> (share: CKShare?, hasRecords: Bool)? {
        // Only the zone's own lookup (and the change fetch) may say "no zone":
        // a share read as gone still leaves the records to be counted.
        let zone: CKRecordZone
        do {
            switch try await database.recordZones(for: [zoneID])[zoneID] {
            case .success(let found)?: zone = found
            case .failure(let error)?: throw error
            case nil: throw CKError(.serverResponseLost)
            }
        } catch let error as CKError where Self.isAlreadyGone(error) {
            return nil
        }
        var share: CKShare?
        if zone.share != nil { share = try await existingZoneShare(in: database, zoneID: zoneID) }
        // One batch tells empty from not (more to come is not empty); the share is a record too.
        let changes: ZoneChanges
        do {
            changes = try await fetchZoneChanges(zone: zoneID, in: database, since: nil, oneBatch: true, desiredKeys: [])
        } catch let error as CKError where Self.isAlreadyGone(error) {
            return nil
        }
        let hasRecords = changes.moreComing
            || changes.records.contains { $0.recordType != CKRecord.SystemType.share }
        return (share, hasRecords)
    }

    /// The confirmed replace. The server's view trails a deletion, so it waits
    /// until the old share reads as gone — or `reopened` would see it and refuse.
    func deleteLeftoverZone(_ zoneID: CKRecordZone.ID, in database: CKDatabase) async throws {
        log.notice("Deleting the previous shared zone before a new invite, as confirmed.")
        do {
            let result = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
            switch result.deleteResults[zoneID] {
            case .success?: break
            case .failure(let error)?: throw error
            case nil: throw SyncError.saveUnconfirmed
            }
        } catch let error as CKError where Self.isAlreadyGone(error) {}
        for attempt in 1...5 {
            if attempt > 1 { try? await Task.sleep(for: .seconds(1)) }
            // A read error isn't "gone": only a clean nil ends the wait.
            do {
                if try await existingZoneShare(in: database, zoneID: zoneID) == nil { return }
            } catch {}
        }
        throw SyncError.zoneUnreachable
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
        return try await saveShare(share, in: database)
    }

    /// The share as the server saved it — never the unsaved local copy (invariant 22).
    func saveShare(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
        try Self.savedShare(try await database.modifyRecords(saving: [share], deleting: []), share.recordID)
    }

    static func savedShare(_ result: ModifyResult, _ id: CKRecord.ID) throws -> CKShare {
        guard let saved = try confirmSaved(result, id) as? CKShare else { throw SyncError.saveUnconfirmed }
        return saved
    }

    /// Reopens a share closed to link-based joining (a local-only reset leaves the
    /// zone and its closed share behind). Only reached after `createPairInvite`'s
    /// leftover check, so anyone on it here is a lookup that raced that check:
    /// refused, never evicted — an eviction handed the next joiner the history.
    func reopened(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
        guard SharePosture(share).memberCount == 0 else { throw SyncError.existingPairing(someoneOnIt: true) }
        guard share.publicPermission != .readWrite else { return share }
        share.publicPermission = .readWrite
        return try await saveShare(share, in: database)
    }

    /// Owner side. Asks the server for the invite link's state — the share is
    /// the durable thing; a cached URL goes stale the moment it's closed elsewhere.
    func inviteState() async throws -> InviteState {
        guard let pairing = try await ownerPairing() else { return .missing }
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

    /// Owner side: `SharePosture.memberCount`. More than one means someone besides
    /// the partner joined through the link. `nil` when there's no share to look at.
    func shareMemberCount() async throws -> Int? {
        guard let pairing = try await ownerPairing() else { return nil }
        guard let share = try await existingZoneShare(in: container.privateCloudDatabase,
                                                      zoneID: zoneID(for: pairing)) else { return nil }
        return SharePosture(share).memberCount
    }

    /// The pairing for an owner share call, `nil` when this side isn't the owner.
    /// Refuses under another iCloud account: the owner's zone ID names whoever is
    /// signed in, so it would reach a stranger's share (invariant 9).
    func ownerPairing() async throws -> PairingInfo? {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner else { return nil }
        try await requireAvailableAccount()
        guard await isPairingAccount(pairing) else { throw SyncError.differentAccount }
        return pairing
    }

    func requireOwnerPairing() async throws -> PairingInfo {
        guard let pairing = try await ownerPairing() else { throw SyncError.notPaired }
        return pairing
    }

    /// Owner side: closes the link so a forwarded copy can't add a third person —
    /// the two-step handshake of invariant 9. Idempotent.
    func lockPairing() async throws {
        let pairing = try await requireOwnerPairing()
        let zoneID = self.zoneID(for: pairing)
        guard let share = try await existingZoneShare(in: container.privateCloudDatabase, zoneID: zoneID) else { return }
        try await closeAndReseat(share, zoneID: zoneID)
    }

    /// Close (which sweeps the public joiner), then re-add them as an invited
    /// private participant, on a share just read.
    private func closeAndReseat(_ share: CKShare, zoneID: CKRecordZone.ID) async throws {
        let database = container.privateCloudDatabase
        if share.publicPermission != .none {
            let publics = share.participants.filter { ShareMember($0).isPublicJoiner }
            // Every public joiner would be re-seated: with anyone beyond the one
            // partner on the share a stranger would be locked in with them.
            let members = SharePosture(share).memberCount
            guard members <= 1 else { throw SyncError.tooManyOnShare(members) }
            // Resolve invite handles before anything is written — a failure
            // here must abort while the partner is still untouched.
            let invited = try await privateParticipants(matching: publics)

            share.publicPermission = .none
            do {
                try Self.confirmSaved(try await database.modifyRecords(saving: [share], deleting: []), share.recordID)
            } catch {
                // The close may have landed despite the error: put the link back first.
                throw await restoreAfterFailedClose(error, zoneID: zoneID, in: database)
            }

            if !invited.isEmpty {
                // From here the partner is off the share until the private seat is
                // confirmed. Any failure reopens the link: left closed, the partner's
                // next refreshes would wipe their history over a vanished zone.
                do {
                    try await promoteToPrivate(invited, zoneID: zoneID, in: database)
                } catch {
                    log.error("Promote failed after the close; reopening the invite link.")
                    throw await restoreAfterFailedClose(error, zoneID: zoneID, in: database)
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
        try Self.confirmSaved(try await database.modifyRecords(saving: [closed], deleting: []), closed.recordID)

        // Verify the invitation landed; pending is success here — the
        // partner's link tap is what flips it to accepted. Polled, since
        // an immediate refetch can trail the save.
        var confirmed: CKShare?
        var partnerInvited = false
        for attempt in 1...5 {
            confirmed = try await existingZoneShare(in: database, zoneID: zoneID)
            partnerInvited = confirmed.map { SharePosture($0).someoneSeatedPrivately } ?? false
            if partnerInvited { break }
            log.notice("Private invitation not visible yet (attempt \(attempt) of 5).")
            try? await Task.sleep(for: .seconds(2))
        }
        guard partnerInvited else {
            let survivors = confirmed.map(SharePosture.init)?.members
                .filter { !$0.isOwner }
                .map { "role \($0.role.rawValue) status \($0.acceptance.rawValue)" }
                .joined(separator: ", ")
            throw SyncError.couldNotSecureShare(
                "the private invitation didn't stick — the server kept: "
                + ((survivors?.isEmpty ?? true) ? "no one but you" : survivors!))
        }
        log.notice("Invite closed; partner re-added as a private participant. Participants now: \(confirmed?.participants.count ?? 0).")
    }

    /// Reopens the link after a failed close, and says honestly whether it
    /// worked: the error the caller surfaces depends on it (`inviteLeftClosed`
    /// tells the owner their partner is locked out and how to reopen).
    func restoreAfterFailedClose(_ error: Error,
                                 zoneID: CKRecordZone.ID,
                                 in database: CKDatabase) async -> Error {
        let detail: String
        switch error {
        case SyncError.couldNotSecureShare(let step): detail = step
        default: detail = error.localizedDescription
        }
        for attempt in 1...3 {
            do {
                try await reopenInvite(zoneID: zoneID, in: database)
                return SyncError.couldNotSecureShare(detail)
            } catch {
                log.error("Reopen attempt \(attempt) of 3 failed: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // The local flag is left alone: the reopen may have failed only because
        // we're offline, and Settings reconciles with the server when it opens.
        return SyncError.inviteLeftClosed(detail)
    }

    /// Puts link-based joining back on. Also Settings' "Reopen the invite link",
    /// the way back from `inviteLeftClosed`.
    func reopenInvite(zoneID: CKRecordZone.ID, in database: CKDatabase) async throws {
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else {
            throw SyncError.shareUnavailable
        }
        if share.publicPermission != .readWrite {
            share.publicPermission = .readWrite
            try Self.confirmSaved(try await database.modifyRecords(saving: [share], deleting: []), share.recordID)
        }
        await MainActor.run { SharedStore.shared.inviteClosed = false }
    }

    /// Owner side, from Settings behind a confirmation.
    func reopenInvite() async throws {
        let pairing = try await requireOwnerPairing()
        try await reopenInvite(zoneID: zoneID(for: pairing), in: container.privateCloudDatabase)
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

    /// Records who the partner is before a block clears the pairing: the owner's
    /// record name for a participant, the share's participants for an owner.
    /// Their invites are refused from then on (`acceptShare`). Returns the names.
    func recordBlockedPartner() async -> [String] {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }) else { return [] }
        var names: [String] = []
        switch pairing.role {
        case .participant:
            names = [pairing.zoneOwnerName]
        case .owner:
            if let owner = try? await ownerPairing(), owner.sameZone(as: pairing),
               let share = try? await existingZoneShare(in: container.privateCloudDatabase,
                                                        zoneID: zoneID(for: pairing)) {
                names = SharePosture(share).otherRecordNames
            }
        }
        guard !names.isEmpty else { return [] }
        let toBlock = names
        await MainActor.run {
            var blocked = SharedStore.shared.blockedOwnerRecordNames
            blocked.formUnion(toBlock)
            SharedStore.shared.blockedOwnerRecordNames = blocked
        }
        return names
    }

    /// Settings' plain close: shuts the link only while nobody has come through
    /// it. With a link-joined partner on the share, closing evicts them — that is
    /// the promote handshake, which needs the owner's explicit go-ahead (invariant 9).
    func closeUnusedInvite() async throws {
        let pairing = try await requireOwnerPairing()
        let database = container.privateCloudDatabase
        guard let share = try await existingZoneShare(in: database, zoneID: zoneID(for: pairing)) else {
            return
        }
        guard SharePosture(share).memberCount == 0 else {
            throw SyncError.inviteInUse
        }
        if share.publicPermission != .none {
            share.publicPermission = .none
            try Self.confirmSaved(try await database.modifyRecords(saving: [share], deleting: []), share.recordID)
        }
        await MainActor.run { SharedStore.shared.inviteClosed = true }
    }

    /// What an explicit close attempt found.
    enum LockOutcome: Sendable {
        case locked
        /// Nobody accepted on the share and the link is open: nothing to secure.
        case nobodyJoined
    }

    /// Confirms a real person is on the share, then promote-and-close. The status
    /// record alone can be a leftover from a previous pairing — only the share's
    /// own participant list is proof, or a fresh invite gets killed unused.
    @discardableResult
    func lockIfPartnerOnShare(_ pairing: PairingInfo) async throws -> LockOutcome {
        guard try await requireOwnerPairing().sameZone(as: pairing) else { throw SyncError.notPaired }
        let zoneID = self.zoneID(for: pairing)
        guard let share = try await existingZoneShare(in: container.privateCloudDatabase, zoneID: zoneID) else {
            throw SyncError.shareUnavailable
        }
        let posture = SharePosture(share)
        guard posture.someoneAccepted else {
            // Closed with nobody accepted is the stranded state a failed reopen
            // leaves — never report it as done.
            if share.publicPermission == .none, !posture.someonePending {
                throw SyncError.inviteLeftClosed("the link is closed and nobody is on the share")
            }
            log.notice("Nobody on the share yet; leaving the invite open.")
            return .nobodyJoined
        }
        try await closeAndReseat(share, zoneID: zoneID)
        log.notice("Partner is on the share — invite link closed.")
        return .locked
    }

    #if DEBUG
    /// Diagnostics maintenance: closes the share, which ejects every link-joined
    /// (public) participant — a link-joined partner included, who must tap the
    /// link again — then reopens it. Nobody's records are touched. Report line either way.
    func sweepPublicJoiners() async -> String {
        do {
            guard let pairing = try await ownerPairing() else { return "Only the owner can sweep the share." }
            let database = container.privateCloudDatabase
            let zoneID = self.zoneID(for: pairing)
            guard let share = try await existingZoneShare(in: database, zoneID: zoneID) else {
                return "No share found."
            }
            let publicCount = SharePosture(share).members.filter { $0.role == .publicUser }.count
            share.publicPermission = .none
            try Self.confirmSaved(try await database.modifyRecords(saving: [share], deleting: []), share.recordID)

            guard let closed = try await existingZoneShare(in: database, zoneID: zoneID) else {
                return "Share unreadable after the sweep — check Diagnostics before sharing the link."
            }
            closed.publicPermission = .readWrite
            try Self.confirmSaved(try await database.modifyRecords(saving: [closed], deleting: []), closed.recordID)
            await MainActor.run { SharedStore.shared.inviteClosed = false }
            return "Swept \(publicCount) public joiner(s); link reopened. "
                + "Participants now: \(closed.participants.count)."
        } catch {
            return "Sweep failed: \(error.localizedDescription)"
        }
    }
    #endif

    /// Diagnostics' trigger for the promote-and-close behind Settings' confirmed
    /// close (`AppModel.closeInviteReseatingPartner`). Returns a report line on failure; `nil` means it worked or there was nothing to do.
    func secureInviteIfPartnerJoined() async -> String? {
        guard let pairing = await MainActor.run(body: { SharedStore.shared.pairing }),
              pairing.role == .owner,
              await MainActor.run(body: { !SharedStore.shared.inviteClosed }) else { return nil }
        do {
            if try await lockIfPartnerOnShare(pairing) == .nobodyJoined {
                return "Nobody has joined through the link yet, so it was left open."
            }
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
        // A blocked person's invite is refused before anything is accepted.
        if let owner = metadata.share.owner.userIdentity.userRecordID?.recordName,
           await MainActor.run(body: { SharedStore.shared.blockedOwnerRecordNames.contains(owner) }) {
            throw SyncError.blocked
        }
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
            // previous partner — unless this is the same zone we were cut loose
            // from, whose unsent media is about to be re-sent.
            SharedStore.shared.clearChangeTokens()
            Self.adoptPairing(info)
        }
        try await bootstrapAfterPairing(displayName: displayName)
    }

    /// Commits a participant-side pairing, keeping local media only when it is
    /// the zone this device last left (`SharedStore.lastPairing`).
    @MainActor
    static func adoptPairing(_ info: PairingInfo) {
        let store = SharedStore.shared
        if store.lastPairing?.sameZone(as: info) != true {
            store.eraseLocalMedia()
        }
        store.lastPairing = nil
        store.pairing = info
    }

    /// The couple's zone as the server still knows it, when this device has no
    /// local pairing — a fresh install on a new phone. A shared-database hit
    /// means this account already accepted the share; a private-database hit
    /// (owner side) only counts with a share attached, since a bare leftover
    /// zone isn't a pairing. `nil` means an invite link is genuinely needed.
    func discoverExistingPairing() async -> (role: PairRole, zoneID: CKRecordZone.ID)? {
        guard await MainActor.run(body: { SharedStore.shared.pairing == nil }) else { return nil }
        guard (try? await accountStatus()) == .available else { return nil }

        let blocked = await MainActor.run { SharedStore.shared.blockedOwnerRecordNames }
        if let zone = try? await container.sharedCloudDatabase.allRecordZones()
            .first(where: { $0.zoneID.zoneName == AppConfig.coupleZoneName
                            && !blocked.contains($0.zoneID.ownerName) }) {
            return (.participant, zone.zoneID)
        }
        if let zone = try? await container.privateCloudDatabase.allRecordZones()
            .first(where: { $0.zoneID.zoneName == AppConfig.coupleZoneName && $0.share != nil }),
           await ownerShareIsRejoinable(zone.zoneID, blocked: blocked) {
            return (.owner, zone.zoneID)
        }
        return nil
    }

    /// A block whose cloud unlink failed leaves the share up, and Rejoin must not
    /// reconnect to that person. A share that couldn't be read is offered only
    /// with nobody blocked — else deleting an intact space would be the only way on.
    func ownerShareIsRejoinable(_ zoneID: CKRecordZone.ID, blocked: Set<String>) async -> Bool {
        let share: CKShare?
        do {
            share = try await existingZoneShare(in: container.privateCloudDatabase, zoneID: zoneID)
        } catch {
            return blocked.isEmpty
        }
        return !(share.map { SharePosture($0).includesAny(of: blocked) } ?? false)
    }

    /// Recommits a pairing found by `discoverExistingPairing` — the account is
    /// already on the share (or owns the zone), so no invite link and no
    /// `CKShare.Metadata` are involved. The cleared tokens make the next
    /// refresh pull the whole zone, which is how the history comes back.
    func rejoin(role: PairRole, zoneID: CKRecordZone.ID, displayName: String) async throws {
        try await requireAvailableAccount()
        if role == .participant {
            try await waitForSharedZone(zoneID)
        } else {
            // Checked again here, not just at discovery: the tap can come much later.
            let blocked = await MainActor.run { SharedStore.shared.blockedOwnerRecordNames }
            guard await ownerShareIsRejoinable(zoneID, blocked: blocked) else { throw SyncError.blocked }
        }

        let info = PairingInfo(role: role,
                               zoneName: zoneID.zoneName,
                               zoneOwnerName: zoneID.ownerName,
                               pairedAt: Date(),
                               userRecordName: await currentUserRecordName())
        await MainActor.run {
            SharedStore.shared.clearChangeTokens()
            Self.adoptPairing(info)
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
                renamed.wordsSince = renamed.wordsAt
                renamed.updatedAt = Date().wholeSeconds
                try await publish(renamed, logged: false)
            }
        } else {
            try await publish(.initial(displayName: displayName))
        }
        let theirs = (try? await refresh())?.partnerStatus
        // Seed watermarks from the server so pairing against existing history
        // doesn't fire stale nudge notifications or mislabel the first push —
        // nor describe the newest of hundreds of re-fetched moments as new.
        // Forward only: an NSE claim can land mid-bootstrap, and a failed
        // refresh (nil) must not reset the count to 0 and re-announce a nudge.
        await MainActor.run {
            _ = SharedStore.shared.mutate {
                if let known = theirs ?? $0.theirs {
                    $0.lastSeenPartnerNudgeCount = max($0.lastSeenPartnerNudgeCount, known.nudgeCount)
                    $0.lastAnnouncedPartnerStatusAt = max($0.lastAnnouncedPartnerStatusAt ?? .distantPast,
                                                          known.updatedAt)
                }
                if let newest = $0.latestPartnerMoment?.sentAt {
                    $0.lastAnnouncedMomentSentAt = max($0.lastAnnouncedMomentSentAt ?? .distantPast, newest)
                }
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
            throw try await zoneGoneVerdict(pairing)
        }
    }

    /// What "the zone isn't there" means right now. Refuses under a *different*
    /// iCloud account — the zone only looks gone there, and wiping would destroy
    /// an intact pairing on both phones. Otherwise the first sighting is only
    /// noted (`zoneUnreachable`): the invite-close handshake takes the partner
    /// off the share for seconds, and a refresh landing then must not wipe
    /// their unsent media. A second sighting `AppConfig.zoneGoneConfirmation`
    /// later is the verdict — this device unlinks itself (`linkEnded`).
    func zoneGoneVerdict(_ pairing: PairingInfo) async throws -> SyncError {
        guard await isPairingAccount(pairing) else {
            log.notice("Zone unreachable, but this is a different iCloud account; keeping local state.")
            throw SyncError.differentAccount
        }
        let now = Date()
        let decision = await MainActor.run { () -> ZoneGonePolicy.Decision in
            let store = SharedStore.shared
            let decision = ZoneGonePolicy.decide(firstSeen: store.zoneGoneSeenAt, now: now)
            if decision == .firstSighting { store.zoneGoneSeenAt = now }
            return decision
        }
        guard decision == .gone else {
            log.notice("Shared zone unreachable; waiting for a second look before unlinking.")
            return .zoneUnreachable
        }
        log.notice("Shared zone is gone (seen twice); unlinking this device.")
        await MainActor.run {
            // Unsent media survives: if this was the close handshake after all,
            // tapping the link again rejoins the same zone and re-sends it.
            SharedStore.shared.eraseLocalMedia(keepingPendingUploads: true)
            // The subscriptions outlive the zone: until they're gone, every
            // write anyone makes under them still pushes here.
            SharedStore.shared.subscriptionCleanup = .init(userRecordName: pairing.userRecordName, since: now)
            SharedStore.shared.clearPairing(keepingName: true)
        }
        return .linkEnded
    }

    /// The zone's share, or `nil` when there isn't one. "Gone" — the zone or its
    /// share — is an answer; any other failure throws, never reads as "no share".
    func existingZoneShare(in database: CKDatabase,
                           zoneID: CKRecordZone.ID) async throws -> CKShare? {
        // `CKShare(recordZoneID:)` always takes this name: one lookup, no zone fetch.
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            return try Self.zoneShare(from: try await database.records(for: [shareID])[shareID])
        } catch let error as CKError where Self.isAlreadyGone(error) {
            log.notice("No existing zone share (CKError \(error.code.rawValue)).")
            return nil
        }
    }

    /// One share lookup's per-item answer, judged the same way.
    static func zoneShare(from result: Result<CKRecord, Error>?) throws -> CKShare? {
        switch result {
        case .success(let record)?:
            guard let share = record as? CKShare else { throw CKError(.serverResponseLost) }
            return share
        case .failure(let error as CKError)? where isAlreadyGone(error):
            return nil
        case .failure(let error)?:
            throw error
        case nil:
            throw CKError(.serverResponseLost)
        }
    }
}
