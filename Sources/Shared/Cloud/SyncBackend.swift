import Foundation

/// What a refresh turned up, so the caller can decide what deserves a
/// notification.
struct RefreshResult: Sendable {
    var partnerStatus: StatusPayload?
    /// Anything the partner sent that this device hadn't already stored,
    /// oldest first. Often several at once — a change fetch returns everything
    /// since the last token, and a fresh install returns the whole zone.
    var newPartnerMoments: [Moment] = []

    var newestPartnerMoment: Moment? { newPartnerMoments.last }

    static let empty = RefreshResult(partnerStatus: nil, newPartnerMoments: [])
}

/// Whether the backend can actually do anything right now.
enum BackendReadiness: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// The whole sync surface the UI depends on, in one place.
///
/// Pairing deliberately isn't here: creating an invite link and accepting one
/// are CloudKit-share flows with their own UI, so `AppModel` calls
/// `CloudSync` directly for those and goes through this for everything else.
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
    func registerSubscription() async throws
    /// Takes this device's data out of the shared space and, for the owner,
    /// removes the space itself.
    ///
    /// Throws rather than swallowing failures: telling someone their photos
    /// are out of the other person's iCloud when the delete never landed is
    /// the one lie this app must not tell. Local state is left alone — the
    /// caller clears it once this has actually succeeded.
    func unpair() async throws
}

/// The backend the app talks to.
enum Backend {
    static var current: any SyncBackend { CloudSync.shared }
}
