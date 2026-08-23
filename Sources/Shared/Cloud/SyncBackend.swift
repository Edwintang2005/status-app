import Foundation

/// What a refresh turned up, so the caller can decide what deserves a
/// notification.
struct RefreshResult: Sendable {
    var partnerStatus: StatusPayload?
    /// Non-nil only when the partner sent something this device hadn't seen.
    var newPartnerMoment: Moment?

    static let empty = RefreshResult(partnerStatus: nil, newPartnerMoment: nil)
}

/// Whether the backend can actually do anything right now.
enum BackendReadiness: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// The operations the UI needs, independent of whether they're backed by
/// CloudKit or by the on-device demo.
///
/// Pairing deliberately isn't here: creating an invite link and starting a
/// demo are genuinely different flows with different UI, so `AppModel` branches
/// on the build for that and shares everything else.
protocol SyncBackend: Sendable {
    func readiness() async -> BackendReadiness
    func publish(_ payload: StatusPayload) async throws
    @discardableResult func refresh() async throws -> RefreshResult
    /// `false` when the cooldown blocked it.
    @discardableResult func sendNudge() async throws -> Bool
    /// Image files are already on disk in the App Group under `moment.id`.
    func send(_ moment: Moment) async throws
    func registerSubscription() async throws
    func unpair() async
}

/// The backend this build talks to.
enum Backend {
    static var current: any SyncBackend {
        #if TETHER_LOCAL_MODE
        return LocalSync.shared
        #else
        return CloudSync.shared
        #endif
    }

    /// True when this build has no CloudKit at all and fakes the other person.
    static var isLocalDemo: Bool {
        #if TETHER_LOCAL_MODE
        return true
        #else
        return false
        #endif
    }
}
