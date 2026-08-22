import Foundation
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// The App Group is the only channel between the app process and the widget
/// extension process. Both read the same `Snapshot`; only the app normally
/// writes it (the exception is `SendNudgeIntent`, which bumps the cooldown).
final class SharedStore {
    static let shared = SharedStore()

    private let defaults: UserDefaults
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "SharedStore")

    private enum Key {
        static let snapshot = "snapshot"
        static let pairing = "pairing"
        static let notificationsRequested = "notificationsRequested"
    }

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else if let suite = UserDefaults(suiteName: AppConfig.appGroupID) {
            self.defaults = suite
        } else {
            // Only happens when the App Group entitlement is missing or the ID
            // is misspelled. Falling back keeps the app usable (as a single
            // device) instead of crashing, and the log says why sync is dead.
            assertionFailure("App Group \(AppConfig.appGroupID) unavailable — check entitlements.")
            self.defaults = .standard
        }
    }

    // MARK: - Snapshot

    var snapshot: Snapshot {
        get { decode(Snapshot.self, forKey: Key.snapshot) ?? .empty }
        set { encode(newValue, forKey: Key.snapshot) }
    }

    /// Read–modify–write plus a widget reload, which is what almost every
    /// caller actually wants.
    @discardableResult
    func mutate(reloadWidgets: Bool = true, _ body: (inout Snapshot) -> Void) -> Snapshot {
        var current = snapshot
        body(&current)
        snapshot = current
        if reloadWidgets { Self.reloadWidgets() }
        return current
    }

    // MARK: - Pairing

    var pairing: PairingInfo? {
        get { decode(PairingInfo.self, forKey: Key.pairing) }
        set {
            if let newValue {
                encode(newValue, forKey: Key.pairing)
            } else {
                defaults.removeObject(forKey: Key.pairing)
            }
        }
    }

    var hasRequestedNotifications: Bool {
        get { defaults.bool(forKey: Key.notificationsRequested) }
        set { defaults.set(newValue, forKey: Key.notificationsRequested) }
    }

    /// Wipes pairing and cached statuses but keeps the nickname, so re-pairing
    /// doesn't lose a preference the user typed.
    func resetPairing() {
        let nickname = snapshot.partnerNickname
        pairing = nil
        snapshot = Snapshot(
            mine: nil,
            theirs: nil,
            partnerNickname: nickname,
            isPaired: false,
            lastSyncedAt: nil,
            lastSeenPartnerNudgeCount: 0,
            lastNudgeSentAt: nil
        )
        Self.reloadWidgets()
    }

    // MARK: - Widgets

    /// `true` when this code is running inside the widget extension rather
    /// than the app.
    static let isRunningInExtension = Bundle.main.bundlePath.hasSuffix(".appex")

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        // A reload requested from inside the widget process would re-enter the
        // timeline provider that just wrote the snapshot. WidgetKit already
        // refreshes after an interactive intent, so extensions never need this.
        guard !isRunningInExtension else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.widgetKind)
        #endif
    }

    // MARK: - Codable plumbing

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder.shared.decode(type, from: data)
        } catch {
            log.error("Failed to decode \(String(describing: type)): \(error.localizedDescription)")
            return nil
        }
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder.shared.encode(value), forKey: key)
        } catch {
            log.error("Failed to encode \(String(describing: T.self)): \(error.localizedDescription)")
        }
    }
}

extension JSONEncoder {
    static let shared: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let shared: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
