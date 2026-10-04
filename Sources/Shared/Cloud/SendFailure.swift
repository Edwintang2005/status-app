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
    /// Anything else: retried on the next refresh.
    case transient

    /// Quota arrives bare (a single save, or `confirmSaved` rethrowing the
    /// record's own error) or per-item inside `.partialFailure`.
    init(_ error: Error) {
        guard let error = error as? CKError else {
            self = .transient
            return
        }
        let itemCodes = error.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.code } ?? []
        if error.code == .quotaExceeded {
            self = .storageFull
        } else if error.code == .partialFailure, itemCodes.contains(.quotaExceeded) {
            self = .storageFull
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
}
