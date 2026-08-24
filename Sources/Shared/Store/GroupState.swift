import Foundation
import os

/// Cross-process key/value storage for everything the app, the widget and the
/// notification service extension have to agree on.
///
/// This exists because `UserDefaults(suiteName:)` is **not** a reliable App
/// Group channel. Observed on the Simulator with correct
/// `com.apple.security.application-groups` entitlements on both binaries: the
/// suite's plist was written to the *app's private* container, leaving the
/// widget process reading an empty suite and rendering as if unpaired, while
/// file access to the same group container worked perfectly from both sides.
/// The group's file container is the channel that actually holds, so shared
/// state goes in files — the same way `MomentIndex` and `MomentStore` already
/// do it.
protocol GroupKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func setData(_ data: Data?, forKey key: String)
    func setBool(_ value: Bool, forKey key: String)
}

/// One small file per key under `<group container>/State/`.
///
/// A file per key rather than one dictionary file, because the writers are
/// separate processes: a whole-file rewrite would make every save a
/// read-modify-write over everyone else's keys, and losing a nudge counter to
/// a lost update is worse than the handful of extra inodes.
final class GroupFileStore: GroupKeyValueStore {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "GroupFileStore")
    private let containerURL: URL?
    /// Where state used to live. Read once, at init, so an app that was already
    /// paired before this change keeps its pairing and history.
    private let legacy: UserDefaults?
    private let lock = NSLock()

    /// Keys carried over from the old `UserDefaults` home. Change-token keys are
    /// matched by prefix; losing one only costs a full resync, but keeping it
    /// saves a device re-downloading its whole zone.
    private static let migratedKeys = ["snapshot", "pairing", "notificationsRequested"]
    private static let migratedPrefixes = ["changeToken-"]
    private static let migrationMarker = ".migrated-from-defaults"

    init(groupID: String = AppConfig.appGroupID, legacy: UserDefaults? = nil) {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("State", isDirectory: true)

        if let container {
            try? FileManager.default.createDirectory(at: container,
                                                     withIntermediateDirectories: true)
        } else {
            // Only happens when the App Group entitlement is missing or the ID
            // is misspelled. The app stays usable as a single device; the log
            // says why the widget is empty.
            assertionFailure("App Group \(groupID) unavailable — check entitlements.")
        }
        self.containerURL = container
        self.legacy = legacy ?? UserDefaults(suiteName: groupID)
        migrateIfNeeded()
    }

    // MARK: - GroupKeyValueStore

    func data(forKey key: String) -> Data? {
        guard let url = url(for: key) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: url)
    }

    func bool(forKey key: String) -> Bool {
        data(forKey: key).map { $0.first == 1 } ?? false
    }

    func setData(_ data: Data?, forKey key: String) {
        guard let url = url(for: key) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            if let data {
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            log.error("Failed to write \(key): \(error.localizedDescription)")
        }
    }

    func setBool(_ value: Bool, forKey key: String) {
        setData(Data([value ? 1 : 0]), forKey: key)
    }

    // MARK: - Migration

    private func url(for key: String) -> URL? {
        // Every key in use is a plain identifier, so it doubles as a filename.
        containerURL?.appendingPathComponent(key)
    }

    /// Copies anything the old `UserDefaults` home still holds, once.
    ///
    /// The marker is written **only** when something was actually copied. The
    /// widget process has its own (empty) view of that suite, so a marker
    /// written from there could otherwise convince the app there was nothing to
    /// migrate and lose the pairing.
    private func migrateIfNeeded() {
        guard let containerURL, let legacy else { return }
        let marker = containerURL.appendingPathComponent(Self.migrationMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        var copied = 0
        for (key, value) in legacy.dictionaryRepresentation() {
            guard Self.migratedKeys.contains(key)
                    || Self.migratedPrefixes.contains(where: key.hasPrefix) else { continue }
            guard let url = url(for: key),
                  !FileManager.default.fileExists(atPath: url.path) else { continue }

            let data: Data?
            switch value {
            case let value as Data: data = value
            case let value as Bool: data = Data([value ? 1 : 0])
            default: data = nil
            }
            guard let data else { continue }
            do {
                try data.write(to: url, options: .atomic)
                copied += 1
            } catch {
                log.error("Couldn't migrate \(key): \(error.localizedDescription)")
            }
        }

        guard copied > 0 else { return }
        log.notice("Migrated \(copied) key(s) out of UserDefaults into the group container.")
        try? Data().write(to: marker, options: .atomic)
    }
}

/// Previews and tests inject a throwaway suite instead of touching the real
/// group container. Correctness in a single process is all that's needed there,
/// which is exactly what `UserDefaults` is still good for.
extension UserDefaults: GroupKeyValueStore {
    func setData(_ data: Data?, forKey key: String) {
        if let data {
            set(data, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }

    func setBool(_ value: Bool, forKey key: String) {
        set(value, forKey: key)
    }
}
