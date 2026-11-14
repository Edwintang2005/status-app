import CloudKit
import XCTest

/// A `SyncBackend` that records what was asked of it and fails on demand.
final class FakeBackend: SyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _published: [(payload: StatusPayload, logged: Bool)] = []
    private var _sent: [String] = []
    private var _captions: [(id: String, caption: String)] = []
    private var _deleted: [[String]] = []
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
    var captions: [(id: String, caption: String)] { lock.withLock { _captions } }
    /// Each `deleteMoments` call's IDs, in order.
    var deleted: [[String]] { lock.withLock { _deleted } }
    /// Runs inside `updateCaption`, before it lands — an edit made mid-flight.
    var duringCaption: (@Sendable () -> Void)?
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
    /// What a refresh reports (`SyncRunner`'s announcements read it).
    var refreshResult = RefreshResult.empty
    /// Answered one per refresh, in order, before `refreshResult`.
    var refreshQueue: [RefreshResult] = []
    private(set) var refreshes = 0
    @discardableResult func refresh() async throws -> RefreshResult {
        try check("refresh")
        return lock.withLock {
            refreshes += 1
            return refreshQueue.isEmpty ? refreshResult : refreshQueue.removeFirst()
        }
    }
    @discardableResult func sendNudge() async throws -> Bool { true }
    func send(_ moment: Moment, progress: @escaping @Sendable (Double) -> Void) async throws {
        await duringSend?(moment.id)
        try check("send")
        lock.withLock { _sent.append(moment.id) }
    }
    /// What `resumeUploads` hands back: uploads iCloud kept running, `nil` for a failed look.
    var backgroundUploads: [ResumedUpload]? = []
    private(set) var resumeCalls = 0
    func resumeUploads() async -> [ResumedUpload]? {
        lock.withLock {
            resumeCalls += 1
            return backgroundUploads
        }
    }
    func fetchMedia(for moment: Moment) async throws {}
    func fetchMedia(for moments: [Moment]) async throws {}
    /// Each archive chunk asked for, in order; `archiveAnswer` answers each (all saved by default).
    var archiveChunks: [[String]] { lock.withLock { _archiveChunks } }
    private var _archiveChunks: [[String]] = []
    var archiveAnswer: @Sendable ([Moment]) async throws -> [String: ArchiveMedia] = { moments in
        Dictionary(uniqueKeysWithValues: moments.map { ($0.id, .saved) })
    }
    func fetchArchiveMedia(_ moments: [Moment], to destinations: [String: URL]) async throws -> [String: ArchiveMedia] {
        lock.withLock { _archiveChunks.append(moments.map(\.id)) }
        return try await archiveAnswer(moments)
    }
    func fetchThumbnails(for moments: [Moment]) async throws {}
    func prefetchRecentMedia() async {}
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
    func deleteMoments(ids: [String]) async throws -> Set<String> {
        try check("delete")
        lock.withLock { _deleted.append(ids) }
        return Set(ids)
    }
    func updateCaption(of moment: Moment) async throws {
        try check("caption")
        duringCaption?()
        lock.withLock { _captions.append((moment.id, moment.caption)) }
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

}

extension Outbox {
    /// An outbox over test doubles: the test passes only the hooks it observes.
    static func testing(store: SharedStore,
                        index: MomentIndex,
                        statusLog: StatusHistoryLog,
                        backend: FakeBackend,
                        hasMedia: @escaping (Moment) -> Bool = { _ in true },
                        uploadSize: @escaping (Moment) -> Int = { _ in 0 },
                        deleteMedia: @escaping (String) -> Void = { _ in },
                        clearRecaps: @escaping () -> Void = {},
                        indexChanged: @escaping () -> Void = {},
                        uploaded: @escaping (Moment) -> Void = { _ in }) -> Outbox {
        Outbox(store: store, index: index, statusLog: statusLog, backend: { backend },
               hasMedia: hasMedia, uploadSize: uploadSize, deleteMedia: deleteMedia,
               clearRecaps: clearRecaps, protect: { _, body in try await body() },
               indexChanged: indexChanged, uploaded: uploaded)
    }
}
