import Foundation

/// Stuck, not slow: an upload is given up only once its bytes stop moving for
/// `AppConfig.uploadStallTimeout`, however long it has run.
struct UploadWatch: Equatable, Sendable {
    enum Verdict: Equatable, Sendable { case moving, stalled }

    private(set) var lastMovedAt: Date
    private(set) var lastTickAt: Date
    private(set) var fraction: Double = 0

    init(startedAt: Date) {
        lastMovedAt = startedAt
        lastTickAt = startedAt
    }

    /// Any change counts — a drop is CloudKit restarting the transfer, still
    /// moving — but a re-report of the same fraction doesn't.
    mutating func progressed(to fraction: Double, at now: Date) {
        guard fraction.isFinite, fraction != self.fraction else { return }
        self.fraction = fraction
        lastMovedAt = max(lastMovedAt, now)
    }

    /// A tick far later than `interval` means the app was suspended while
    /// iCloud carried on uploading unseen — the clock restarts rather than
    /// counting the gap as stalled.
    mutating func tick(at now: Date,
                       interval: TimeInterval = AppConfig.uploadTickInterval,
                       timeout: TimeInterval = AppConfig.uploadStallTimeout) -> Verdict {
        defer { lastTickAt = now }
        if now.timeIntervalSince(lastTickAt) > interval * 3 {
            lastMovedAt = now
            return .moving
        }
        // Preparing the asset before the first byte, and the commit after the
        // last, report nothing: those quiet phases get twice as long.
        let allowed = fraction <= 0 || fraction >= 1 ? timeout * 2 : timeout
        return now.timeIntervalSince(lastMovedAt) >= allowed ? .stalled : .moving
    }
}

/// The order a retry pass sends waiting moments in.
enum UploadOrder {
    /// Smallest first, so a drawing or voice memo isn't stuck behind a photo
    /// on a weak link; equal sizes keep their index order.
    static func smallestFirst(_ moments: [Moment], size: (Moment) -> Int) -> [Moment] {
        moments.enumerated()
            .map { (offset: $0.offset, moment: $0.element, size: size($0.element)) }
            .sorted { ($0.size, $0.offset) < ($1.size, $1.offset) }
            .map(\.moment)
    }
}
