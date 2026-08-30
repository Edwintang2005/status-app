import Foundation
import os

/// Cross-process key/value storage shared by the app, widget and notification
/// extension. Files, not `UserDefaults(suiteName:)` — the suite's plist can land
/// in the app's private container, leaving extensions reading an empty suite.
protocol GroupKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func setData(_ data: Data?, forKey key: String)
    func setBool(_ value: Bool, forKey key: String)
}

/// One file per key under `<group container>/State/` — a single dictionary file
/// would make every save a cross-process read-modify-write over all keys.
final class GroupFileStore: GroupKeyValueStore {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "GroupFileStore")
    private let containerURL: URL?
    /// Old `UserDefaults` home; read at init so pre-existing pairings survive.
    private let legacy: UserDefaults?
    private let lock = NSLock()

    /// Keys migrated from `UserDefaults`; change tokens matched by prefix.
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
            // App Group entitlement missing or ID misspelled; app stays usable
            // single-device.
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

    /// One-time copy out of `UserDefaults`. The marker is written only when
    /// something was copied — the widget's empty view of the suite must not
    /// mark migration done and lose the pairing.
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

/// Previews/tests inject a throwaway suite instead of the real group container.
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
