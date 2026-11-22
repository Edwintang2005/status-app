import Foundation
import os

/// What the invite link asks of the model that owns it. Held weakly.
@MainActor
protocol InviteLinkHost: AnyObject {
    var isPaired: Bool { get }
    var role: PairRole? { get }
    /// The partner has published a status: they're in.
    var partnerIsIn: Bool { get }
    var partnerNameInSentence: String { get }
    /// The store moved: re-read it.
    func reload()
    func present(_ error: Error, title: String?)
}

/// The owner's invite link: its URL and whether it's open, who is on the share,
/// and the manual close, re-seat and reopen (invariant 9), one change at a time.
@MainActor
@Observable
final class InviteLinkModel {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "InviteLink")

    /// The link to hand to the partner, kept after the invite closes: the same
    /// link re-admits the existing partner on a new phone. Seeded from the store.
    private(set) var url: URL?
    /// Revoked from Settings or Diagnostics.
    private(set) var isClosed: Bool
    /// The server has no share at all (vs. one that was closed) — keeps Settings from spinning.
    private(set) var isUnavailable = false
    /// The server's view of the link backs Home's close prompt this launch.
    private(set) var postureChecked = false
    /// A close or reopen is in flight. Its own flag: nothing else ending may
    /// clear it mid-handshake and admit a second close.
    private(set) var isChanging = false
    /// Bumped at both ends of every change, so a posture check that started
    /// before or during one can't write its older answer over it.
    @ObservationIgnored private var changes = 0
    /// Settings asks before the re-seat: set when a plain close found someone
    /// on the share (or the partner is known to be in).
    var confirmingReseat = false
    /// Settings' result line after a close or reopen.
    var notice: String?
    /// People other than the owner on the share, from the last check. More than
    /// one is the stranger warning.
    private(set) var memberCount: Int?
    @ObservationIgnored private var membersCheckedAt: Date?
    private(set) var promptDismissed: Bool

    @ObservationIgnored weak var host: (any InviteLinkHost)?
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored private let backend: () -> any AppBackend
    /// Demo mode's pairing is fake: the share checks would read (and the close
    /// would act on) whatever real share the signed-in account has.
    @ObservationIgnored private let usesLiveShare: Bool

    init(store: SharedStore, backend: @escaping () -> any AppBackend, usesLiveShare: Bool) {
        self.store = store
        self.backend = backend
        self.usesLiveShare = usesLiveShare
        url = store.inviteURL
        isClosed = store.inviteClosed
        promptDismissed = store.closeLinkPromptDismissed
    }

    private var isOwner: Bool { host?.isPaired == true && host?.role == .owner }

    /// Re-reads the store; unlinked, what the last share check said goes too.
    func reload() {
        if isClosed != store.inviteClosed { isClosed = store.inviteClosed }
        // The closed link is kept on purpose — see `refreshURL`.
        if url != store.inviteURL { url = store.inviteURL }
        if promptDismissed != store.closeLinkPromptDismissed { promptDismissed = store.closeLinkPromptDismissed }
        guard host?.isPaired != true else { return }
        if memberCount != nil { memberCount = nil }
        membersCheckedAt = nil
        if postureChecked { postureChecked = false }
    }

    /// A new invite was made: its link.
    func adopt(_ url: URL) {
        setURL(url)
    }

    /// Unlinked: `clearPairing` already cleared the stored copy.
    func forget() {
        url = nil
    }

    // MARK: Home's prompts

    /// Owner side, once the partner is in and the server says the link is still
    /// open (the cached flag alone goes stale across devices and rejoins).
    var showsClosePrompt: Bool {
        usesLiveShare && isOwner && host?.partnerIsIn == true
            && postureChecked && !isClosed && !promptDismissed && extraMembers == nil
    }

    /// More people on the share than the one partner, or `nil`.
    var extraMembers: Int? {
        guard usesLiveShare, isOwner, let count = memberCount, count > 1 else { return nil }
        return count
    }

    func dismissClosePrompt() {
        store.closeLinkPromptDismissed = true
        promptDismissed = true
    }

    // MARK: Reading the share

    /// Counts who is on the share and re-reads whether the link is open.
    /// Throttled from the refresh pass; Settings asks directly. Quiet on
    /// failure — the last answer stands.
    /// - Returns: the state it read, for `refreshURL`; `nil` when it didn't
    ///   look, couldn't, or a close or reopen overtook it.
    @discardableResult
    func checkMembers(throttled: Bool, now: Date = Date()) async -> InviteState? {
        guard usesLiveShare, isOwner else { return nil }
        // Open, Home's prompt needs this launch's own look; closed, nobody new can
        // join, so a look from an earlier launch counts, and daily is enough.
        let closed = store.inviteClosed
        let interval = closed ? AppConfig.closedShareCheckInterval : AppConfig.shareMemberCheckInterval
        if throttled, let last = membersCheckedAt ?? (closed ? store.shareCheckedAt : nil),
           now.timeIntervalSince(last) < interval { return nil }
        let changesBefore = changes
        let backend = backend()
        let check: ShareCheck
        do {
            check = try await withDeadline(AppConfig.publishDeadline) { try await backend.shareCheck() }
        } catch {
            Self.log.error("Couldn't read the share: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        memberCount = check.memberCount
        membersCheckedAt = now
        store.shareCheckedAt = now
        let state = check.invite
        // A close or reopen landed meanwhile: its answer is newer than ours.
        guard changes == changesBefore, !isChanging else { return nil }
        switch state {
        case .open:
            setClosed(false)
            postureChecked = true
        case .closed:
            setClosed(true)
            postureChecked = true
        case .missing:
            // No share to close: nothing verified.
            postureChecked = false
        }
        return state
    }

    /// Reconciles the cached link against the server. Quiet on failure — the
    /// cached link still shows, and the next attempt tries again.
    func refreshURL() async {
        guard usesLiveShare else {
            // Demo mode's fake pairing has no share to look at: say so, don't spin.
            isUnavailable = url == nil
            return
        }
        guard host?.role == .owner, let state = await checkMembers(throttled: false) else { return }
        switch state {
        case .open(let url):
            setURL(url)
            isUnavailable = false
        case .closed(let url):
            // How this device finds out the invite was closed from another.
            // The URL is kept: it re-admits the existing partner on a new
            // phone, and admits nobody else.
            setURL(url)
            isUnavailable = false
        case .missing:
            // No link to offer, but nothing says the partner joined — don't claim closed.
            setURL(nil)
            isUnavailable = true
        }
    }

    private func setClosed(_ closed: Bool) {
        guard isClosed != closed else { return }
        store.inviteClosed = closed
        isClosed = closed
    }

    private func setURL(_ url: URL?) {
        store.inviteURL = url
        self.url = url
    }

    // MARK: Changing the link

    /// Runs one close or reopen under `isChanging`.
    private func withChange<T>(_ body: () async -> T) async -> T {
        isChanging = true
        changes += 1
        defer { isChanging = false; changes += 1 }
        return await body()
    }

    #if DEBUG
    /// Diagnostics' sweep, under the same flag: it closes and reopens the share,
    /// which can evict a link-joined partner.
    func sweepPublicJoiners() async -> String {
        guard usesLiveShare else { return "Demo mode: the share isn't touched." }
        guard !isChanging else { return "A close or reopen is already running." }
        let line = await withChange { await CloudSync.shared.sweepPublicJoiners() }
        host?.reload()
        await refreshURL()
        return line
    }
    #endif

    /// Diagnostics' promote-and-close, under the same flag as Settings' so the
    /// two can't race. Returns the report line (`nil`: done or nothing to do).
    func secureFromDiagnostics() async -> String? {
        guard usesLiveShare else { return "Demo mode: the share isn't touched." }
        guard !isChanging else { return "A close or reopen is already running." }
        let backend = backend()
        return await withChange { await backend.secureInviteIfPartnerJoined() }
    }

    /// Settings' close. With the partner in, closing re-seats them, which only
    /// ever runs after the owner confirms (invariant 9).
    func close() async {
        guard usesLiveShare, !isChanging else { return }
        if host?.partnerIsIn == true {
            confirmingReseat = true
            return
        }
        let backend = backend()
        await withChange {
            do {
                try await backend.closeUnusedInvite()
                // The URL is kept — a closed link still re-admits the existing partner.
                setClosed(true)
            } catch SyncError.inviteInUse {
                confirmingReseat = true
            } catch {
                host?.present(error, title: String(localized: "Couldn't change the invite link"))
            }
        }
    }

    /// The confirmed re-seat: close the link, re-add the partner privately.
    func closeReseatingPartner() async {
        // A second confirmation mid-handshake would race the first's close and re-add.
        guard usesLiveShare, !isChanging, let pairing = store.pairing, pairing.role == .owner else { return }
        let backend = backend()
        let name = host?.partnerNameInSentence ?? ""
        await withChange {
            do {
                switch try await backend.lockIfPartnerOnShare(pairing) {
                case .locked:
                    notice = String(localized: "The link is closed. Ask \(name) to tap the invite link once more to get back in.")
                case .nobodyJoined:
                    // Nobody *accepted*; a pending private partner survives a close,
                    // which `closeUnusedInvite` would refuse. The full lock handles both.
                    try await backend.lockPairing()
                    notice = String(localized: "The link is closed.")
                }
            } catch {
                host?.present(error, title: String(localized: "Couldn't change the invite link"))
            }
        }
        // After the change has ended: inside it, the posture check refuses to run.
        host?.reload()
        await refreshURL()
    }

    /// Settings' reopen, behind a confirmation: anyone with the link can join again.
    func reopen() async {
        guard usesLiveShare, !isChanging else { return }
        let backend = backend()
        let name = host?.partnerNameInSentence ?? ""
        await withChange {
            do {
                try await backend.reopenInvite()
                notice = String(localized: "The link is open again. Anyone who has it can join, so send it only to \(name) — if they lost access, they tap it to get back in.")
            } catch {
                host?.present(error, title: String(localized: "Couldn't change the invite link"))
            }
        }
        // After the change has ended: inside it, the posture check refuses to run.
        host?.reload()
        await refreshURL()
    }
}
