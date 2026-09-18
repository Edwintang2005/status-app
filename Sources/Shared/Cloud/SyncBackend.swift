import Foundation

/// What a refresh turned up, so the caller can decide what deserves a
/// notification.
struct RefreshResult: Sendable {
    var partnerStatus: StatusPayload?
    /// New partner moments, oldest first. Often several at once — a fresh
    /// install's change fetch returns the whole zone.
    var newPartnerMoments: [Moment] = []
    /// Records this pass couldn't decrypt; `CloudSync.refresh` then keeps the
    /// change token so they come round again.
    var unreadableRecordNames: [String] = []
    /// This device's own records changed on the server — written by another
    /// device on the same iCloud account. The notification service words its
    /// banner accordingly rather than crediting the partner.
    var ownRecordsChanged = false
    /// An extension took one batch of a larger delta and left the rest for the
    /// app (`CloudSync.fetchZoneChanges`); the pushed record may not be in it.
    var incomplete = false

    var unreadableRecords: Int { unreadableRecordNames.count }
    var newestPartnerMoment: Moment? { newPartnerMoments.last }

    static let empty = RefreshResult(partnerStatus: nil, newPartnerMoments: [])
}

/// Whether the backend can actually do anything right now.
enum BackendReadiness: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// The whole sync surface the UI depends on. Pairing deliberately isn't here —
/// the share flows have their own UI, so `AppModel` calls `CloudSync` directly for those.
protocol SyncBackend: Sendable {
    func readiness() async -> BackendReadiness
    /// `logged: false` for a rename — the status didn't change, so no `StatusLog` record.
    func publish(_ payload: StatusPayload, logged: Bool) async throws
    @discardableResult func refresh() async throws -> RefreshResult
    /// `false` when the cooldown blocked it.
    @discardableResult func sendNudge() async throws -> Bool
    /// Media files are already on disk in the App Group under `moment.id`.
    func send(_ moment: Moment) async throws
    /// Pulls the media files for a history entry whose photo or recording
    /// isn't cached locally any more. No-op for backends that never evict.
    func fetchMedia(for moment: Moment) async throws
    /// Pulls only the thumbnail — what a library tile needs when it scrolls into
    /// view past the cache window. No-op for voice memos and for backends that never evict.
    func fetchThumbnail(for moment: Moment) async throws
    /// Publishes this device's read-receipt seen-map ({momentID: seenAt}) and
    /// which partner status it has had on screen; an empty map and `nil`
    /// retract. No-op for backends without a partner.
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws
    /// Owner only: writes the pair's anniversary, or deletes it with `nil`.
    func publishAnniversary(_ anniversary: Anniversary?) async throws
    /// Participant only: asks the owner to set the date. Fixed record name,
    /// so re-asking overwrites.
    func publishAnniversaryRequest(at date: Date) async throws
    func registerSubscription() async throws
    /// The system said the iCloud account changed; the next `readiness()` must
    /// re-check it for real rather than trust its cache.
    func noteAccountChanged() async
    /// Takes this device's data out of the shared space (the owner removes the space
    /// itself). Throws rather than swallowing — claiming the photos are gone when the
    /// delete never landed is the one lie this app must not tell. The caller clears
    /// local state only after success.
    func unpair() async throws
}

extension SyncBackend {
    func publish(_ payload: StatusPayload) async throws {
        try await publish(payload, logged: true)
    }
}

/// Runs `body` or gives up after `seconds`. For the widget and its intent:
/// WidgetKit kills the process past its budget, and a kill mid-write leaves
/// claims (the nudge cooldown) unreleased. On the deadline `body` is cancelled
/// and left to finish on its own — a task group would wait for it, and the
/// auto-imported CloudKit calls ignore cancellation — so the caller returns on
/// time while `body`'s own cancellation checks take its failure path.
func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                               _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let settled = DeadlineSettled()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            let result: Result<T, Error>
            do { result = .success(try await body()) } catch { result = .failure(error) }
            if settled.claim() { continuation.resume(with: result) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard settled.claim() else { return }
            work.cancel()
            // The body finishing first leaves this sleeper to run out; harmless.
            continuation.resume(throwing: CancellationError())
        }
    }
}

/// One resume per continuation, whichever of the body and the deadline lands first.
private final class DeadlineSettled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// The backend the app talks to.
enum Backend {
    static var current: any SyncBackend {
        #if DEBUG
        if DemoMode.isActive { return DemoBackend() }
        #endif
        return CloudSync.shared
    }
}

#if DEBUG
/// Screenshot mode: `REDSTRING_DEMO=1` swaps CloudKit for an always-succeeding
/// backend so the app runs on a Simulator with no iCloud account. Debug-only and
/// environment-gated — a normal launch never comes near it.
enum DemoMode {
    static let isActive = ProcessInfo.processInfo.environment["REDSTRING_DEMO"] == "1"
}

struct DemoBackend: SyncBackend {
    func readiness() async -> BackendReadiness { .ready }
    func publish(_ payload: StatusPayload, logged: Bool) async throws {}
    @discardableResult func refresh() async throws -> RefreshResult { .empty }
    @discardableResult func sendNudge() async throws -> Bool {
        SharedStore.shared.mutate { snapshot in
            snapshot.lastNudgeSentAt = Date()
            var mine = snapshot.mine ?? .initial(displayName: "")
            mine.nudgeCount += 1
            mine.lastNudgeAt = Date()
            snapshot.mine = mine
        }
        return true
    }
    func send(_ moment: Moment) async throws {}
    func fetchMedia(for moment: Moment) async throws {}
    func fetchThumbnail(for moment: Moment) async throws {}
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws {}
    func publishAnniversary(_ anniversary: Anniversary?) async throws {}
    func publishAnniversaryRequest(at date: Date) async throws {}
    func registerSubscription() async throws {}
    func noteAccountChanged() async {}
    func unpair() async throws {}
}
#endif
