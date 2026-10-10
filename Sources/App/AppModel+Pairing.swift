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
                      _ commit: (any SyncBackend, String) async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setName(trimmed)

        do {
            try await commit(backend, trimmed)
            reload()
            await NotificationManager.requestAuthorizationIfNeeded()
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
    func checkForRejoinablePairing() async {
        guard !isPaired, pendingInvite == nil else { return }
        rejoinablePairing = await backend.discoverExistingPairing()
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
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await backend.createPairInvite(displayName: myDisplayName,
                                                         replacingExisting: replacingExisting)
            setInviteURL(url)
            reload()
            // After `reload()`, which flips `isPaired` and dismisses the pairing screen.
            presentedInvite = InviteLink(url: url)
            // Owed once the link sheet closes — see `RootView`.
            persist(true, \.anniversaryPromptPending, \.anniversaryPromptPending)
            await NotificationManager.requestAuthorizationIfNeeded()
        } catch SyncError.existingPairing(let someoneOnIt) {
            // Nothing written: offer Rejoin, or the confirmed replace — asked
            // only once discovery says whether Rejoin is there to offer.
            await checkForRejoinablePairing()
            replacingSpaceHasPartner = someoneOnIt
            confirmingReplacePairing = true
        } catch {
            // `createPairInvite` commits the pairing before its bootstrap publish;
            // reload so the store and this model can't disagree.
            reload()
            present(error, title: String(localized: "Couldn't create the link"))
        }
    }

    // MARK: - Invite link posture (manual close only — invariant 9)

    /// Owner side, once the partner is in and the server says the link is still
    /// open (the cached flag alone goes stale across devices and rejoins).
    var showsCloseLinkPrompt: Bool {
        usesLiveShare && isPaired && role == .owner && snapshot.theirs != nil
            && invitePostureChecked && !inviteClosed
            && !closeLinkPromptDismissed && extraShareMembers == nil
    }

    /// More people on the share than the one partner, or `nil`.
    var extraShareMembers: Int? {
        guard usesLiveShare, isPaired, role == .owner, let count = shareMemberCount, count > 1 else { return nil }
        return count
    }

    /// Demo mode's pairing is fake: the share checks would read (and the close
    /// would act on) whatever real share the signed-in account has.
    private var usesLiveShare: Bool {
        #if DEBUG
        return !DemoMode.isActive
        #else
        return true
        #endif
    }

    func dismissCloseLinkPrompt() {
        persist(true, \.closeLinkPromptDismissed, \.closeLinkPromptDismissed)
    }

    /// Counts who is on the share and re-reads whether the link is open.
    /// Throttled from the refresh pass; Settings asks directly. Quiet on
    /// failure — the last answer stands.
    func checkShareMembers(throttled: Bool) async {
        guard usesLiveShare, isPaired, role == .owner else { return }
        if throttled, let last = shareMembersCheckedAt,
           Date().timeIntervalSince(last) < AppConfig.shareMemberCheckInterval { return }
        let changesBefore = inviteChanges
        do {
            let (count, state) = try await bounded { (try await $0.shareMemberCount(), try await $0.inviteState()) }
            shareMembersCheckedAt = Date()
            shareMemberCount = count
            // A close or reopen landed meanwhile: its answer is newer than ours.
            guard inviteChanges == changesBefore, !isChangingInviteLink else { return }
            switch state {
            case .open:
                setInviteClosed(false)
                invitePostureChecked = true
            case .closed:
                setInviteClosed(true)
                invitePostureChecked = true
            case .missing:
                // No share to close: nothing verified.
                invitePostureChecked = false
            }
        } catch {
            log.error("Couldn't count the share's members: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reconciles the cached invite link against the server. Quiet on failure —
    /// the cached link still shows, and the next attempt tries again.
    func refreshInviteURL() async {
        guard usesLiveShare else {
            // Demo mode's fake pairing has no share to look at: say so, don't spin.
            inviteLinkUnavailable = inviteURL == nil
            return
        }
        guard role == .owner else { return }
        await checkShareMembers(throttled: false)
        let changesBefore = inviteChanges
        do {
            let state = try await backend.inviteState()
            // A close or reopen landed meanwhile: its answer is newer than ours.
            guard inviteChanges == changesBefore, !isChangingInviteLink else { return }
            switch state {
            case .open(let url):
                setInviteURL(url)
                setInviteClosed(false)
                inviteLinkUnavailable = false
            case .closed(let url):
                // How this device finds out the invite was closed from another.
                // The URL is kept: it re-admits the existing partner on a new
                // phone, and admits nobody else.
                setInviteURL(url)
                setInviteClosed(true)
                inviteLinkUnavailable = false
            case .missing:
                // No link to offer, but nothing says the partner joined — don't claim closed.
                setInviteURL(nil)
                inviteLinkUnavailable = true
            }
        } catch {
            // Couldn't reach iCloud: keep the cached link and stay quiet.
            log.error("Couldn't refresh the invite link: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setInviteClosed(_ closed: Bool) {
        guard inviteClosed != closed else { return }
        persist(closed, \.inviteClosed, \.inviteClosed)
    }

    private func setInviteURL(_ url: URL?) {
        persist(url, \.inviteURL, \.inviteURL)
    }

    /// Runs one close or reopen under `isChangingInviteLink`. `inviteChanges` is
    /// bumped at both ends: a posture check that started mid-change is stale too.
    private func withInviteChange<T>(_ body: () async -> T) async -> T {
        isChangingInviteLink = true
        inviteChanges += 1
        defer { isChangingInviteLink = false; inviteChanges += 1 }
        return await body()
    }

    /// Diagnostics' promote-and-close, under the same flag as Settings' so the
    /// two can't race. Returns the report line (`nil`: done or nothing to do).
    func secureInviteFromDiagnostics() async -> String? {
        guard usesLiveShare else { return "Demo mode: the share isn't touched." }
        guard !isChangingInviteLink else { return "A close or reopen is already running." }
        let backend = backend
        return await withInviteChange { await backend.secureInviteIfPartnerJoined() }
    }

    /// Settings' close. With the partner in, closing re-seats them, which only
    /// ever runs after the owner confirms (invariant 9).
    func closeInvite() async {
        guard usesLiveShare, !isChangingInviteLink else { return }
        if snapshot.theirs != nil {
            confirmingInviteReseat = true
            return
        }
        let backend = backend
        await withInviteChange {
            do {
                try await backend.closeUnusedInvite()
                // The URL is kept — a closed link still re-admits the existing partner.
                setInviteClosed(true)
            } catch SyncError.inviteInUse {
                confirmingInviteReseat = true
            } catch {
                present(error, title: String(localized: "Couldn't change the invite link"))
            }
        }
    }

    /// The confirmed re-seat: close the link, re-add the partner privately.
    func closeInviteReseatingPartner() async {
        // A second confirmation mid-handshake would race the first's close and re-add.
        guard usesLiveShare, !isChangingInviteLink, let pairing = store.pairing, pairing.role == .owner else { return }
        let backend = backend
        await withInviteChange {
            do {
                switch try await backend.lockIfPartnerOnShare(pairing) {
                case .locked:
                    inviteNotice = String(localized: "The link is closed. Ask \(partnerName) to tap the invite link once more to get back in.")
                case .nobodyJoined:
                    // Nobody *accepted*; a pending private partner survives a close,
                    // which `closeUnusedInvite` would refuse. The full lock handles both.
                    try await backend.lockPairing()
                    inviteNotice = String(localized: "The link is closed.")
                }
            } catch {
                present(error, title: String(localized: "Couldn't change the invite link"))
            }
            reload()
            await refreshInviteURL()
        }
    }

    /// Settings' reopen, behind a confirmation: anyone with the link can join again.
    func reopenInvite() async {
        guard usesLiveShare, !isChangingInviteLink else { return }
        let backend = backend
        await withInviteChange {
            do {
                try await backend.reopenInvite()
                inviteNotice = String(localized: "The link is open again. Anyone who has it can join, so send it only to \(partnerName) — if they lost access, they tap it to get back in.")
            } catch {
                present(error, title: String(localized: "Couldn't change the invite link"))
            }
            reload()
            await refreshInviteURL()
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
        isBusy = true
        defer { isBusy = false }

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
        store.eraseLocalMedia()
        store.clearPairing(keepingName: !startingOver)
        inviteURL = nil  // `clearPairing` already cleared the stored copy.
        pendingInvite = nil
        reload()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
