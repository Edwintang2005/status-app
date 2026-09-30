import CloudKit

/// Why a send failed, as far as the wording and the retry pacing care.
enum SendFailure: Equatable, Sendable {
    /// The zone owner's iCloud is full. Both people's sends count against it,
    /// and nothing lands until they free space — retrying every refresh only burns data.
    case storageFull
    /// Anything else: retried on the next refresh.
    case transient

    /// Quota arrives bare (a single save, or `confirmSaved` rethrowing the
    /// record's own error) or per-item inside `.partialFailure`.
    init(_ error: Error) {
        guard let error = error as? CKError else {
            self = .transient
            return
        }
        if error.code == .quotaExceeded {
            self = .storageFull
        } else if error.code == .partialFailure,
                  error.partialErrorsByItemID?.values.contains(where: { ($0 as? CKError)?.code == .quotaExceeded }) == true {
            self = .storageFull
        } else {
            self = .transient
        }
    }
}
