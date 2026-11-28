import Foundation

/// When automatic retries may go again — every send loop's backoff in one place
/// (`Outbox`). A throttle holds every automatic pass until its retry-after or
/// anything landing. A full iCloud holds, for `storageFullRetryInterval`, the
/// uploads it refused — and every write once even a few bytes were refused; never
/// deletes, which free room. Per send, one refused outright waits (`hold`) and
/// one failing repeatedly backs off (`backOff`). In memory; a tap never asks.
struct RetryPacing: Equatable, Sendable {
    /// What was sent, for what its landing or refusal says about space.
    enum Send: Sendable {
        case delete, write, upload
    }

    /// What a per-send hold is about — refused uploads and caption edits by moment,
    /// the status as one, earlier statuses' logs as another.
    enum Subject: Hashable, Sendable {
        case upload(String)
        case caption(String)
        case status
        case history
    }

    private(set) var storageFullAt: Date?
    /// A write of a few bytes was refused for space too: nothing fits.
    private(set) var nothingFitsAt: Date?
    private(set) var throttledUntil: Date?
    private var notBefore: [Subject: Date] = [:]
    private var failures: [Subject: Int] = [:]

    /// Deletes: only a throttle holds them.
    func allowsAutomaticDeletes(now: Date) -> Bool {
        guard let until = throttledUntil else { return true }
        return now >= until
    }

    /// Writes also wait out a full iCloud that refused one.
    func allowsAutomatic(now: Date) -> Bool {
        allowsAutomaticDeletes(now: now) && Self.waitedOut(nothingFitsAt, now: now)
    }

    /// Uploads also wait out a full iCloud that refused a photo.
    func allowsAutomaticUploads(now: Date) -> Bool {
        allowsAutomatic(now: now) && Self.waitedOut(storageFullAt, now: now)
    }

    /// A stamp from the future (a clock change) doesn't hold.
    private static func waitedOut(_ full: Date?, now: Date) -> Bool {
        guard let full, full <= now else { return true }
        return now.timeIntervalSince(full) >= AppConfig.storageFullRetryInterval
    }

    /// The pass-wide holds, then this send's own.
    func allowsAutomatic(_ subject: Subject, now: Date) -> Bool {
        let passes = if case .upload = subject { allowsAutomaticUploads(now: now) } else { allowsAutomatic(now: now) }
        return passes && now >= (notBefore[subject] ?? .distantPast)
    }

    /// Stamps a full iCloud or a throttle; returns the failure, classified.
    @discardableResult
    mutating func noteFailure(_ error: Error, sending: Send = .write, now: Date) -> SendFailure {
        let failure = SendFailure(error, now: now)
        switch failure {
        case .storageFull:
            storageFullAt = now
            if sending != .upload { nothingFitsAt = now }
        case .throttled(let until): throttledUntil = max(throttledUntil ?? .distantPast, until)
        case .offline, .rejected, .transient: break
        }
        return failure
    }

    /// Anything landing proves we're let through; a write that a few bytes fit, an
    /// upload that a photo does. A delete, often of something already gone, proves no room.
    mutating func noteSuccess(_ sent: Send) {
        throttledUntil = nil
        if sent != .delete { nothingFitsAt = nil }
        if sent == .upload { storageFullAt = nil }
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
