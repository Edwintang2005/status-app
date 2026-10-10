import CloudKit
import XCTest

/// A `SyncBackend` that records what was asked of it and fails on demand.
final class FakeBackend: SyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _published: [(payload: StatusPayload, logged: Bool)] = []
    private var _sent: [String] = []
    private var _receipts: [[String: Date]] = []
    private var _statusSeen: [StatusSeen?] = []
    private var _anniversaries: [Anniversary?] = []
    private var _requests: [Date] = []
    private var _freshStartIntents: [FreshStartIntent] = []
    private var _clears: [(epoch: Date, keep: Date?)] = []
    private var _freshStartServer: FreshStartRecord?
    /// The server's clock for an ask's save.
    var freshStartSavedAt = Fixtures.date(1_000)
    /// What a clear reports of the zone.
    var clearZone = FreshStartPolicy.Zone()
    /// Runs inside `clearHistory` — a send landing mid-clear.
    var duringClear: (@Sendable () -> Void)?
    private var failures: [String: [Error]] = [:]
    /// Runs inside the call, before it returns — a write landing mid-flight.
    var duringPublish: (@Sendable () -> Void)?
    var duringReceipts: (@Sendable () -> Void)?
    var duringAnniversary: (@Sendable () -> Void)?
    /// Runs inside `send`, before it lands — a refresh's retry pass mid-upload.
    var duringSend: (@Sendable (String) async -> Void)?

    var published: [(payload: StatusPayload, logged: Bool)] { lock.withLock { _published } }
    var sent: [String] { lock.withLock { _sent } }
    var receipts: [[String: Date]] { lock.withLock { _receipts } }
    var statusSeen: [StatusSeen?] { lock.withLock { _statusSeen } }
    var anniversaries: [Anniversary?] { lock.withLock { _anniversaries } }
    var requests: [Date] { lock.withLock { _requests } }
    var freshStartIntents: [FreshStartIntent] { lock.withLock { _freshStartIntents } }
    var clears: [(epoch: Date, keep: Date?)] { lock.withLock { _clears } }
    /// Our `FreshStart` record as the fake server holds it.
    var freshStartServer: FreshStartRecord? {
        get { lock.withLock { _freshStartServer } }
        set { lock.withLock { _freshStartServer = newValue } }
    }

    /// The next `count` calls to `method` throw `error`.
    func fail(_ method: String, with error: Error, times count: Int = 1) {
        lock.withLock { failures[method, default: []] += Array(repeating: error, count: count) }
    }

    private func check(_ method: String) throws {
        let error: Error? = lock.withLock {
            guard var queue = failures[method], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            failures[method] = queue
            return first
        }
        if let error { throw error }
    }

    func readiness() async -> BackendReadiness { .ready }
    func publish(_ payload: StatusPayload, logged: Bool) async throws {
        duringPublish?()
        try check("publish")
        lock.withLock { _published.append((payload, logged)) }
    }
    @discardableResult func refresh() async throws -> RefreshResult { .empty }
    @discardableResult func sendNudge() async throws -> Bool { true }
    func send(_ moment: Moment) async throws {
        await duringSend?(moment.id)
        try check("send")
        lock.withLock { _sent.append(moment.id) }
    }
    func fetchMedia(for moment: Moment) async throws {}
    func fetchThumbnails(for moments: [Moment]) async throws {}
    func archiveZone() async throws -> ArchiveContents.Zone {
        ArchiveContents.Zone(moments: [], statuses: [], unreadable: 0)
    }
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws {
        duringReceipts?()
        try check("receipts")
        lock.withLock {
            _receipts.append(seen)
            _statusSeen.append(statusSeen)
        }
    }
    func publishAnniversary(_ anniversary: Anniversary?) async throws {
        try check("anniversary")
        duringAnniversary?()
        lock.withLock { _anniversaries.append(anniversary) }
    }
    func publishAnniversaryRequest(at date: Date) async throws {
        try check("request")
        duringAnniversary?()
        lock.withLock { _requests.append(date) }
    }
    /// The real transition rule against the fake server copy.
    func publishFreshStart(_ intent: FreshStartIntent) async throws -> FreshStartPublishResult {
        try check("freshStart")
        return lock.withLock {
            _freshStartIntents.append(intent)
            switch FreshStartPolicy.transition(intent, from: _freshStartServer) {
            case .write(var record):
                if record.stage == .asking { record.epoch = freshStartSavedAt }
                _freshStartServer = record
                return .saved(record)
            case .unchanged(let record):
                return .saved(record)
            case .refused(let record):
                return .refused(record)
            }
        }
    }
    func clearHistory(before epoch: Date, keepingStatusLogAt keep: Date?) async throws -> FreshStartPolicy.Zone {
        duringClear?()
        try check("clear")
        return lock.withLock {
            _clears.append((epoch, keep))
            return clearZone
        }
    }
    func registerSubscription() async throws {}
    func noteAccountChanged() async {}
    func unpair() async throws {}

    // The outbox never pairs or touches the share.
    func createPairInvite(displayName: String, replacingExisting: Bool) async throws -> URL {
        throw SyncError.shareUnavailable
    }
    func acceptShare(_ metadata: CKShare.Metadata, displayName: String) async throws {}
    func reacceptShare(_ metadata: CKShare.Metadata) async throws {}
    func discoverExistingPairing() async -> (role: PairRole, zoneID: CKRecordZone.ID)? { nil }
    func rejoin(role: PairRole, zoneID: CKRecordZone.ID, displayName: String) async throws {}
    func inviteState() async throws -> InviteState { .missing }
    func shareMemberCount() async throws -> Int? { nil }
    func closeUnusedInvite() async throws {}
    func lockIfPartnerOnShare(_ pairing: PairingInfo) async throws -> CloudSync.LockOutcome { .nobodyJoined }
    func lockPairing() async throws {}
    func reopenInvite() async throws {}
    func secureInviteIfPartnerJoined() async -> String? { nil }
    func recordBlockedPartner() async -> [String] { [] }
    func deleteAllSubscriptions(ownedBy userRecordName: String?) async throws {}
}

extension Outbox {
    /// An outbox over test doubles: the test passes only the hooks it observes.
    static func testing(store: SharedStore,
                        index: MomentIndex,
                        statusLog: StatusHistoryLog,
                        backend: FakeBackend,
                        hasMedia: @escaping (Moment) -> Bool = { _ in true },
                        deleteMedia: @escaping (String) -> Void = { _ in },
                        indexChanged: @escaping () -> Void = {},
                        uploaded: @escaping (Moment) -> Void = { _ in }) -> Outbox {
        Outbox(store: store, index: index, statusLog: statusLog, backend: { backend },
               hasMedia: hasMedia, deleteMedia: deleteMedia,
               protect: { _, body in try await body() },
               indexChanged: indexChanged, uploaded: uploaded)
    }
}
