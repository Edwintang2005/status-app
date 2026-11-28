import CloudKit
import Foundation
import os
import UIKit

// Joining, the invite link and its posture checks, and ending the link.
extension AppModel {
    // MARK: - Onboarding

    /// Invite sender's name — only available when they're discoverable by
    /// Apple Account, so the joining screen has to read well without it.
    var pendingInviteOwnerName: String? {
        guard let components = pendingInvite?.ownerIdentity.nameComponents else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .short)
        return name.isEmpty ? nil : name
    }

    /// Called when a share link opens the app; held so the welcome screen can ask for a name first.
    /// Refused while paired: joining a second zone would break the change tokens and mix galleries.
    func receiveInvite(_ metadata: CKShare.Metadata) {
        guard !isPaired else {
            let zoneID = metadata.share.recordID.zoneID
            if let pairing = store.pairing,
               zoneID.zoneName == pairing.zoneName,
               zoneID.ownerName == pairing.zoneOwnerName {
                // Our own share's link: not a new pairing, a confirmation — how
                // a partner left `pending` by the promote handshake accepts
                // their private seat.
                let backend = backend
                Task {
                    try? await backend.reacceptShare(metadata)
                    await refresh()
                }
            } else {
                errorTitle = String(localized: "Already linked")
                errorMessage = String(localized: "You're already linked with \(partnerName). To join a new invite, unlink first in Settings.")
            }
            return
        }
        pendingInvite = metadata
    }

    /// The name the invitee entered on the joining screen, then the join.
    func acceptInvite(name: String) async {
        guard let metadata = pendingInvite else { return }
        // On failure the invite is kept — the link is still the way in.
        await join(name: name, failureTitle: String(localized: "Couldn't join")) { backend, trimmed in
            try await backend.acceptShare(metadata, displayName: trimmed)
            self.pendingInvite = nil
        }
    }

    /// The name, then `commit`, then the first fetch. A failure reloads first:
    /// the join commits the pairing before its bootstrap publish, so the store may already say paired.
    private func join(name: String,
                      failureTitle: String,
                      _ commit: (any AppBackend, String) async throws -> Void) async {
        pairingOperation = .joining
        defer { endPairingOperation(.joining) }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setName(trimmed)

        do {
            try await commit(backend, trimmed)
            reload()
            await environment.requestNotificationAuthorization()
            await refresh()
        } catch {
            reload()
            present(error, title: failureTitle)
        }
    }

    /// Backing out of a join — the invite is dropped.
    func declineInvite() {
        pendingInvite = nil
    }

    /// Looks for a pairing the server still holds for this account — a fresh
    /// install on a new phone can rejoin it without a new invite link.
    /// A look that couldn't tell is tried again a few times while the pairing
    /// screen is up (its `.task` cancels the waits): never read as "nothing there".
    func checkForRejoinablePairing(retrying: Bool = true) async {
        // One look when the caller is waiting on it (the invite button).
        for delay in retrying ? [0, 3, 10, 30] : [0] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, !isPaired, pendingInvite == nil else { return }
            switch await backend.discoverExistingPairing() {
            case .found(let role, let zoneID):
                rejoinablePairing = (role, zoneID)
                return
            case .none:
                rejoinablePairing = nil
                return
            case .unknown:
                log.notice("Couldn't tell whether a shared space exists; trying again.")
            }
        }
    }

    /// Recommits the discovered pairing under the name from the pairing screen.
    func rejoin(name: String) async {
        guard let found = rejoinablePairing else { return }
        await join(name: name, failureTitle: String(localized: "Couldn't rejoin")) { backend, trimmed in
            try await backend.rejoin(role: found.role, zoneID: found.zoneID, displayName: trimmed)
            self.rejoinablePairing = nil
        }
    }

    // MARK: - Pairing

    /// `RootView`'s own sheets over Home: the invite link and the date prompt
    /// (mirrors that sheet's condition).
    var rootSheetShowing: Bool {
        presentedInvite != nil
            || ((anniversaryPromptPending || anniversaryRequestPending) && canEditAnniversary && !homeSheetShowing)
    }

    /// `replacingExisting` only after the user confirmed deleting the old space.
    func createInvite(replacingExisting: Bool = false) async {
        pairingOperation = .creatingInvite
        defer { endPairingOperation(.creatingInvite) }
        do {
            let url = try await backend.createPairInvite(displayName: myDisplayName,
                                                         replacingExisting: replacingExisting)
            invite.adopt(url)
            reload()
            // After `reload()`, which flips `isPaired` and dismisses the pairing screen.
            presentedInvite = InviteLink(url: url)
            // Owed once the link sheet closes — see `RootView`.
            persist(true, \.anniversaryPromptPending, \.anniversaryPromptPending)
            await environment.requestNotificationAuthorization()
        } catch SyncError.existingPairing(let someoneOnIt) {
            // Nothing written: offer Rejoin, or the confirmed replace — asked
            // only once discovery says whether Rejoin is there to offer.
            await checkForRejoinablePairing(retrying: false)
            replacingSpaceHasPartner = someoneOnIt
            confirmingReplacePairing = true
        } catch {
            // `createPairInvite` commits the pairing before its bootstrap publish;
            // reload so the store and this model can't disagree.
            reload()
            present(error, title: String(localized: "Couldn't create the link"))
        }
    }

    // MARK: - Ending it

    /// Ends the link, cloud first, then locally. Order matters: if iCloud can't be
    /// cleaned up we keep the pairing and change nothing — a local reset that leaves
    /// photos in someone else's iCloud must not look like it didn't.
    /// - Parameter startingOver: also forgets your name.
    /// - Returns: `false` if nothing was changed.
    @discardableResult
    func unlink(startingOver: Bool) async -> Bool {
        pairingOperation = .unlinking
        defer { endPairingOperation(.unlinking) }

        do {
            try await backend.unpair()
        } catch {
            present(error, title: String(localized: "Couldn't unlink"))
            return false
        }

        finishUnlink(startingOver: startingOver)
        return true
    }

    /// Cuts this device loose without touching iCloud — for when the delete can't
    /// go through and waiting isn't acceptable. The caller must say what stays behind.
    func forceLocalReset(startingOver: Bool) {
        finishUnlink(startingOver: startingOver)
    }

    func finishUnlink(startingOver: Bool) {
        // Until both databases confirm, the ex's writes may keep pushing here.
        store.subscriptionCleanup = .init(userRecordName: store.pairing?.userRecordName, since: Date())
        Task { await cleanUpSubscriptionsIfNeeded() }
        stores.eraseLocalMedia()
        store.clearPairing(keepingName: !startingOver)
        invite.forget()
        pendingInvite = nil
        // Statuses set for them aren't suggestions for whoever comes next.
        let forget = environment.donateStatus
        Task { await forget(nil) }
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

extension AppModel: InviteLinkHost {
    var partnerIsIn: Bool { snapshot.theirs != nil }
}
