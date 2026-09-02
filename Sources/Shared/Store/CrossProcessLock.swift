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
        return try Self.resistingSuspension {
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

    /// Being suspended while holding a shared-container file lock is a `0xdead10cc`
    /// kill, so the process holds a system activity assertion for the (millisecond)
    /// critical section. `performExpiringActivity` is extension-safe, unlike UIKit
    /// background tasks. `body` stays on the caller's thread — callers' closures
    /// touch actor-isolated state.
    private static func resistingSuspension<T>(_ body: () throws -> T) rethrows -> T {
        let granted = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "CrossProcessLock") { expired in
            // Called once with `false` when time is granted and, should it run out
            // first, again with `true`. `true` on the first call means no time at
            // all is available; the body then runs unprotected, as it always did.
            granted.signal()
            if !expired { released.wait() }
        }
        // Bounded so a stalled system queue can only delay the caller, never hang it;
        // `released` is signalled either way, so a late block returns at once.
        _ = granted.wait(timeout: .now() + 1)
        defer { released.signal() }
        return try body()
    }
}
