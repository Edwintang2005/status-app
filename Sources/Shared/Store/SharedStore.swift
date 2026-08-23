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

    /// Wipes pairing, cached statuses and the whole moment history.
    func resetPairing() {
        pairing = nil
        MomentIndex.shared.clear()
        MomentStore.shared.prune(keeping: [])
        for key in ["private", "shared"] { setChangeToken(nil, for: key) }
        snapshot = Snapshot(
            mine: nil,
            theirs: nil,
            isPaired: false,
            lastSyncedAt: nil,
            lastSeenPartnerNudgeCount: 0,
            lastNudgeSentAt: nil,
            latestPartnerMoment: nil,
            latestOwnMoment: nil,
            lastNotifiedMomentID: nil
        )
        Self.reloadWidgets()
    }

    // MARK: - Widgets

    /// `true` only inside the WidgetKit extension — deliberately not "any
    /// extension", because the notification service extension *does* need to
    /// reload widgets: it may be the only part of the app that runs when a
    /// photo arrives on a force-quit phone.
    static let isRunningInWidgetExtension: Bool = {
        guard let extensionInfo = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any],
              let point = extensionInfo["NSExtensionPointIdentifier"] as? String else {
            return false
        }
        return point == "com.apple.widgetkit-extension"
    }()

    /// Files the moment in the durable history index, promotes it to the
    /// snapshot if it's the newest in its direction, and trims cached images.
    func record(_ moments: [Moment]) {
        guard !moments.isEmpty else { return }
        let all = MomentIndex.shared.insert(moments)

        mutate(reloadWidgets: false) { snapshot in
            if let newestTheirs = all.first(where: { !$0.fromMe }) {
                snapshot.latestPartnerMoment = newestTheirs
            }
            if let newestMine = all.first(where: { $0.fromMe }) {
                snapshot.latestOwnMoment = newestMine
            }
        }

        // Keep every entry in the index but only recent images on disk; older
        // ones are re-fetched from CloudKit when the gallery reaches them.
        let keep = all.prefix(AppConfig.momentImageCacheLimit).map(\.id)
        MomentStore.shared.prune(keeping: keep)
        Self.reloadWidgets()
    }

    func record(_ moment: Moment) {
        record([moment])
    }

    // MARK: - CloudKit change tokens

    /// Opaque per-zone `CKServerChangeToken`, so a sync only asks for what has
    /// changed. Clearing it makes the next sync pull the entire zone, which is
    /// how a reinstalled app recovers its whole history.
    func changeToken(for key: String) -> Data? {
        defaults.data(forKey: "changeToken-\(key)")
    }

    func setChangeToken(_ data: Data?, for key: String) {
        let name = "changeToken-\(key)"
        if let data {
            defaults.set(data, forKey: name)
        } else {
            defaults.removeObject(forKey: name)
        }
    }

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        // A reload requested from inside the widget process would re-enter the
        // timeline provider that just wrote the snapshot. WidgetKit already
        // refreshes after an interactive intent, so it never needs this.
        guard !isRunningInWidgetExtension else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.momentWidgetKind)
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
