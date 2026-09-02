import Foundation

/// What a refresh turned up, so the caller can decide what deserves a
/// notification.
struct RefreshResult: Sendable {
    var partnerStatus: StatusPayload?
    /// New partner moments, oldest first. Often several at once — a fresh
    /// install's change fetch returns the whole zone.
    var newPartnerMoments: [Moment] = []

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
    func publish(_ payload: StatusPayload) async throws
    @discardableResult func refresh() async throws -> RefreshResult
    /// `false` when the cooldown blocked it.
    @discardableResult func sendNudge() async throws -> Bool
    /// Media files are already on disk in the App Group under `moment.id`.
    func send(_ moment: Moment) async throws
    /// Pulls the media files for a history entry whose photo or recording
    /// isn't cached locally any more. No-op for backends that never evict.
    func fetchMedia(for moment: Moment) async throws
    /// Publishes this device's read-receipt seen-map ({momentID: seenAt}) and
    /// which partner status it has had on screen; an empty map and `nil`
    /// retract. No-op for backends without a partner.
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws
    func registerSubscription() async throws
    /// Takes this device's data out of the shared space (the owner removes the space
    /// itself). Throws rather than swallowing — claiming the photos are gone when the
    /// delete never landed is the one lie this app must not tell. The caller clears
    /// local state only after success.
    func unpair() async throws
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
    func publish(_ payload: StatusPayload) async throws {}
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
    func publishReceipts(_ seen: [String: Date], statusSeen: StatusSeen?) async throws {}
    func registerSubscription() async throws {}
    func unpair() async throws {}
}
#endif
