import CloudKit
import Foundation

/// `FakeBackend` plus the pairing half `AppModel` needs: a scripted share,
/// and a record of every change asked of it.
final class FakeAppBackend: FakeBackend, PairingBackend, @unchecked Sendable {
    private let pairingLock = NSLock()
    private var _share = ShareCheck(memberCount: 1, invite: .open(URL(string: "https://www.icloud.com/share/test")!))
    private var _calls: [String] = []
    private var _lockOutcome = CloudSync.LockOutcome.locked
    private var _inviteInUse = false

    /// What `shareCheck` answers.
    var share: ShareCheck {
        get { pairingLock.withLock { _share } }
        set { pairingLock.withLock { _share = newValue } }
    }
    var lockOutcome: CloudSync.LockOutcome {
        get { pairingLock.withLock { _lockOutcome } }
        set { pairingLock.withLock { _lockOutcome = newValue } }
    }
    /// `closeUnusedInvite` finds someone on the share.
    var inviteInUse: Bool {
        get { pairingLock.withLock { _inviteInUse } }
        set { pairingLock.withLock { _inviteInUse = newValue } }
    }
    /// Pairing calls, by name, in order.
    var calls: [String] { pairingLock.withLock { _calls } }
    /// Runs inside the share-changing calls, before they return — a check landing mid-change.
    var duringChange: (@Sendable () async -> Void)?
    /// Runs inside `shareCheck`, before it answers — a change landing while a look is out.
    var duringShareCheck: (@Sendable () async -> Void)?

    private func note(_ call: String) {
        pairingLock.withLock { _calls.append(call) }
    }

    func createPairInvite(displayName: String, replacingExisting: Bool) async throws -> URL {
        note("createPairInvite")
        return URL(string: "https://www.icloud.com/share/new")!
    }
    func acceptShare(_ metadata: CKShare.Metadata, displayName: String) async throws { note("acceptShare") }
    func reacceptShare(_ metadata: CKShare.Metadata) async throws { note("reacceptShare") }
    func discoverExistingPairing() async -> PairingDiscovery { .none }
    func rejoin(role: PairRole, zoneID: CKRecordZone.ID, displayName: String) async throws { note("rejoin") }
    func shareCheck() async throws -> ShareCheck {
        note("shareCheck")
        let answer = share
        await duringShareCheck?()
        return answer
    }
    func closeUnusedInvite() async throws {
        note("closeUnusedInvite")
        await duringChange?()
        if inviteInUse { throw SyncError.inviteInUse }
    }
    func lockIfPartnerOnShare(_ pairing: PairingInfo) async throws -> CloudSync.LockOutcome {
        note("lockIfPartnerOnShare")
        await duringChange?()
        return lockOutcome
    }
    func lockPairing() async throws { note("lockPairing") }
    func reopenInvite() async throws {
        note("reopenInvite")
        await duringChange?()
    }
    func secureInviteIfPartnerJoined() async -> String? {
        note("secureInviteIfPartnerJoined")
        return nil
    }
    func recordBlockedPartner() async -> [String] { [] }
    func deleteAllSubscriptions(ownedBy userRecordName: String?) async throws {}
}
