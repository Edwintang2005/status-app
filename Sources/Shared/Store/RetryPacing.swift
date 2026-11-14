import Foundation

/// When automatic retries may go again — every send loop's backoff in one place
/// (`Outbox`). Two holds stop every automatic pass: a full iCloud (for
/// `storageFullRetryInterval`, or until anything lands) and a throttle (until
/// iCloud's retry-after). Then per send: one iCloud refused outright waits a fixed
/// interval (`hold`), and one failing repeatedly backs off, doubling (`backOff`).
/// In memory: after a relaunch, one try finds out again. A tap never asks.
struct RetryPacing: Equatable, Sendable {
    /// What a per-send hold is about — refused uploads and caption edits by moment,
    /// the status as one.
    enum Subject: Hashable, Sendable {
        case upload(String)
        case caption(String)
        case status
    }

    private(set) var storageFullAt: Date?
    private(set) var throttledUntil: Date?
    private var notBefore: [Subject: Date] = [:]
    private var failures: [Subject: Int] = [:]

    /// Neither a full iCloud nor a throttle holds automatic passes now. A full
    /// stamp from the future (a clock change) doesn't hold.
    func allowsAutomatic(now: Date) -> Bool {
        if let until = throttledUntil, now < until { return false }
        guard let full = storageFullAt, full <= now else { return true }
        return now.timeIntervalSince(full) >= AppConfig.storageFullRetryInterval
    }

    /// The pass-wide holds, then this send's own.
    func allowsAutomatic(_ subject: Subject, now: Date) -> Bool {
        allowsAutomatic(now: now) && now >= (notBefore[subject] ?? .distantPast)
    }

    /// Stamps a full iCloud or a throttle; returns the failure, classified.
    @discardableResult
    mutating func noteFailure(_ error: Error, now: Date) -> SendFailure {
        let failure = SendFailure(error, now: now)
        switch failure {
        case .storageFull: storageFullAt = now
        case .throttled(let until): throttledUntil = max(throttledUntil ?? .distantPast, until)
        case .offline, .rejected, .transient: break
        }
        return failure
    }

    /// Anything landing proves there's room again, and that we're let through.
    mutating func noteSuccess() {
        storageFullAt = nil
        throttledUntil = nil
    }

    /// Refused outright: automatic passes skip it for `interval`.
    mutating func hold(_ subject: Subject, for interval: TimeInterval, now: Date) {
        notBefore[subject] = now.addingTimeInterval(interval)
    }

    /// Failed again for a reason other than no route: the wait doubles, from
    /// `statusRetryBaseDelay` up to `statusRetryMaxDelay`.
    mutating func backOff(_ subject: Subject, now: Date) {
        let count = (failures[subject] ?? 0) + 1
        failures[subject] = count
        notBefore[subject] = now.addingTimeInterval(Self.backOffDelay(failures: count))
    }

    /// Sent: its holds and its count go.
    mutating func clear(_ subject: Subject) {
        notBefore[subject] = nil
        failures[subject] = nil
    }

    static func backOffDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let doubled = AppConfig.statusRetryBaseDelay * pow(2, Double(min(failures - 1, 16)))
        return min(doubled, AppConfig.statusRetryMaxDelay)
    }
}
