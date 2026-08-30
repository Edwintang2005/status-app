import Foundation
import os

/// Mutual exclusion across the app, widget and notification-service *processes*
/// (`NSLock` only covers one process). POSIX `flock` on a group-container file:
/// kernel-released if the holder dies, and contends correctly across threads too.
final class CrossProcessLock: @unchecked Sendable {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "CrossProcessLock")
    private let url: URL?

    /// `name` is the lock file's name in the group container root. Never
    /// re-acquire the same name while already held — it self-deadlocks.
    init(name: String) {
        url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent(name)
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        // No group container means no second process can see the files either;
        // callers' own NSLocks cover single-process correctness.
        guard let url else { return try body() }
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            log.error("Couldn't open lock file \(url.lastPathComponent): errno \(errno)")
            return try body()
        }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX) != 0 {
            log.error("flock failed on \(url.lastPathComponent): errno \(errno)")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
