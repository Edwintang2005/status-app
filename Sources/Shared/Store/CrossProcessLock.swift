import Foundation
import os

/// Mutual exclusion across the app, widget and notification-service
/// *processes*, which all read-modify-write the same App Group files. An
/// `NSLock` only serialises threads within one process — two processes each
/// holding their own lock can still interleave a read-modify-write and
/// silently lose the other's update, and they're triggered by the same
/// events, so they collide by design.
///
/// A POSIX `flock` on a dedicated file in the group container is the right
/// tool: it's released by the kernel if the holder dies (a jetsammed
/// extension can't wedge the app), and two separate opens of the same file
/// contend correctly whether they're in different processes or different
/// threads of this one.
final class CrossProcessLock: @unchecked Sendable {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "CrossProcessLock")
    private let url: URL?

    /// `name` is the lock file's name in the group container root. Distinct
    /// resources use distinct names; the same name must never be acquired
    /// while already held (flock between two opens self-deadlocks).
    init(name: String) {
        url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent(name)
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        // No group container means no second process can see the files
        // either — single-process correctness is all that's left to protect,
        // and the callers' own NSLocks already do that.
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
