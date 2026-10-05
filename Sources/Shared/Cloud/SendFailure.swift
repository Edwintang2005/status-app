import CloudKit

/// Why a send failed, as far as the wording and the retry pacing care.
enum SendFailure: Equatable, Sendable {
    /// The zone owner's iCloud is full. Both people's sends count against it,
    /// and nothing lands until they free space — retrying every refresh only burns data.
    case storageFull
    /// No route at all (`networkUnavailable`): quiet — the footer says it's
    /// waiting — and a retry pass stops. `networkFailure` is CFNetwork's
    /// catch-all (a dropped upload, TLS, a proxy) and stays transient.
    case offline
    /// CloudKit asked us to slow down (`requestRateLimited`, `zoneBusy`,
    /// `serviceUnavailable`): nothing automatic until `until` — retrying sooner
    /// can extend the throttle.
    case throttled(until: Date)
    /// Anything else: retried on the next refresh.
    case transient

    /// Quota arrives bare (a single save, or `confirmSaved` rethrowing the
    /// record's own error) or per-item inside `.partialFailure`; so does a throttle.
    init(_ error: Error, now: Date = Date()) {
        guard let error = error as? CKError else {
            self = .transient
            return
        }
        let items = error.partialErrorsByItemID?.values.compactMap { $0 as? CKError } ?? []
        let itemCodes = items.map(\.code)
        if error.code == .quotaExceeded {
            self = .storageFull
        } else if error.code == .partialFailure, itemCodes.contains(.quotaExceeded) {
            self = .storageFull
        } else if Self.isThrottle(error.code) {
            self = .throttled(until: now.addingTimeInterval(Self.delay(error.retryAfterSeconds)))
        } else if error.code == .partialFailure, let throttle = items.first(where: { Self.isThrottle($0.code) }) {
            let delay = Self.delay(throttle.retryAfterSeconds ?? error.retryAfterSeconds)
            self = .throttled(until: now.addingTimeInterval(delay))
        } else if Self.isNetwork(error.code) {
            self = .offline
        } else if error.code == .partialFailure, !itemCodes.isEmpty,
                  itemCodes.allSatisfy({ Self.isNetwork($0) || $0 == .batchRequestFailed }),
                  itemCodes.contains(where: Self.isNetwork) {
            self = .offline
        } else {
            self = .transient
        }
    }

    private static func isNetwork(_ code: CKError.Code) -> Bool {
        code == .networkUnavailable
    }

    private static func isThrottle(_ code: CKError.Code) -> Bool {
        code == .requestRateLimited || code == .zoneBusy || code == .serviceUnavailable
    }

    /// The server's own figure, within reason: a crafted or absurd one can't
    /// park the queue for days.
    private static func delay(_ retryAfter: TimeInterval?) -> TimeInterval {
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else { return AppConfig.throttleDefaultDelay }
        return min(retryAfter, AppConfig.storageFullRetryInterval)
    }
}
