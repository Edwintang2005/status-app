import Foundation
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// App Group state shared between the app, widget and notification processes.
/// File-backed, not `UserDefaults` — see `GroupFileStore` for why.
final class SharedStore {
    static let shared = SharedStore()

    private let store: GroupKeyValueStore
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "SharedStore")

    private enum Key {
        static let snapshot = "snapshot"
        static let pairing = "pairing"
        static let notificationsRequested = "notificationsRequested"
        static let inviteClosed = "inviteClosed"
        static let inviteURL = "inviteURL"
        static let readReceipts = "readReceiptsEnabled"
        static let termsVersion = "acceptedTermsVersion"
        static let contentFilter = "contentFilterEnabled"
        static let hiddenMoments = "hiddenMomentIDs"
        static let hiddenStatusAt = "hiddenPartnerStatusAt"
        static let blockedOwners = "blockedOwnerRecordNames"
    }

    init(store: GroupKeyValueStore = GroupFileStore()) {
        self.store = store
    }

    /// Previews and tests: an isolated defaults suite, never the real container.
    convenience init(defaults: UserDefaults) {
        self.init(store: defaults)
    }

    // MARK: - Snapshot

    var snapshot: Snapshot {
        get { decode(Snapshot.self, forKey: Key.snapshot) ?? .empty }
        set { encode(newValue, forKey: Key.snapshot) }
    }

    /// The snapshot has writers in three processes (app, widget, notification
    /// service); without this lock, concurrent read-modify-writes lose updates.
    private static let snapshotLock = CrossProcessLock(name: "snapshot.lock")

    /// Locked read–modify–write plus a widget reload.
    @discardableResult
    func mutate(reloadWidgets: Bool = true, _ body: (inout Snapshot) -> Void) -> Snapshot {
        let result = Self.snapshotLock.withLock {
            var current = snapshot
            body(&current)
            snapshot = current
            return current
        }
        if reloadWidgets { Self.reloadWidgets() }
        return result
    }

    // MARK: - Pairing

    var pairing: PairingInfo? {
        get { decode(PairingInfo.self, forKey: Key.pairing) }
        set {
            if let newValue {
                encode(newValue, forKey: Key.pairing)
            } else {
                store.setData(nil, forKey: Key.pairing)
            }
        }
    }

    var hasRequestedNotifications: Bool {
        get { store.bool(forKey: Key.notificationsRequested) }
        set { store.setBool(newValue, forKey: Key.notificationsRequested) }
    }

    /// Whether this device sends (and shows) read receipts. On by default —
    /// an absent key reads `true`, so the value is stored as explicit bytes
    /// rather than through `bool(forKey:)`, where unset and `false` collapse.
    /// Gates both directions — see `AppModel.readReceiptsEnabled`.
    var readReceiptsEnabled: Bool {
        get { store.data(forKey: Key.readReceipts).map { $0.first == 1 } ?? true }
        set { store.setData(Data([newValue ? 1 : 0]), forKey: Key.readReceipts) }
    }

    // MARK: - Safety (guideline 1.2)

    /// Highest `AppConfig.termsVersion` the user has agreed to; 0 = never.
    var acceptedTermsVersion: Int {
        get { store.data(forKey: Key.termsVersion).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0 }
        set { store.setData(Data(String(newValue).utf8), forKey: Key.termsVersion) }
    }

    /// The on-device word filter over the partner's text. On by default —
    /// stored as explicit bytes for the same reason as `readReceiptsEnabled`.
    var contentFilterEnabled: Bool {
        get { store.data(forKey: Key.contentFilter).map { $0.first == 1 } ?? true }
        set { store.setData(Data([newValue ? 1 : 0]), forKey: Key.contentFilter) }
    }

    /// Reported moments: removed locally and kept out of every later delta
    /// (`CloudSync.apply` drops them), since the record itself lives on in the
    /// sender's iCloud. Written only by the app, so no cross-process lock.
    var hiddenMomentIDs: Set<String> {
        get { decode(Set<String>.self, forKey: Key.hiddenMoments) ?? [] }
        set { encode(newValue, forKey: Key.hiddenMoments) }
    }

    /// `updatedAt` of a reported partner status; its text is never shown while
    /// that status is current. Cleared with the pairing.
    var hiddenPartnerStatusAt: Date? {
        get { decode(Date.self, forKey: Key.hiddenStatusAt) }
        set {
            if let newValue {
                encode(newValue, forKey: Key.hiddenStatusAt)
            } else {
                store.setData(nil, forKey: Key.hiddenStatusAt)
            }
        }
    }

    /// CloudKit user record names of blocked people; their invites are refused.
    /// Survives unlink and "start over" — a block is meant to stick.
    var blockedOwnerRecordNames: Set<String> {
        get { decode(Set<String>.self, forKey: Key.blockedOwners) ?? [] }
        set { encode(newValue, forKey: Key.blockedOwners) }
    }

    /// Owner side: cached "invite link revoked" flag so `CloudSync` stops
    /// re-checking a closed share; the share's `publicPermission` is the truth.
    var inviteClosed: Bool {
        get { store.bool(forKey: Key.inviteClosed) }
        set { store.setBool(newValue, forKey: Key.inviteClosed) }
    }

    /// Owner side: cached invite link so Settings can show it instantly and
    /// offline; `CloudSync.inviteState()` is the truth.
    var inviteURL: URL? {
        get {
            guard let data = store.data(forKey: Key.inviteURL),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: text)
        }
        set {
            store.setData(newValue?.absoluteString.data(using: .utf8), forKey: Key.inviteURL)
        }
    }

    /// Forgets the pairing, both statuses and the sync cursors. `keepingName`
    /// preserves the display name (unlink) vs. fresh-install reset (start over).
    func clearPairing(keepingName: Bool) {
        // Locked: a mid-flight notification-service read-modify-write could
        // otherwise resurrect the pre-unlink snapshot after this wipe.
        Self.snapshotLock.withLock {
            let name = keepingName
                ? snapshot.mine?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil

            pairing = nil
            // The next pairing gets a new share with a new link, which starts open.
            inviteClosed = false
            inviteURL = nil
            hiddenPartnerStatusAt = nil
            for key in ["private", "shared"] { setChangeToken(nil, for: key) }
            snapshot = Snapshot(
                mine: (name?.isEmpty == false) ? .initial(displayName: name!) : nil,
                theirs: nil,
                isPaired: false,
                lastSyncedAt: nil,
                lastSeenPartnerNudgeCount: 0,
                lastNudgeSentAt: nil,
                latestPartnerMoment: nil,
                latestOwnMoment: nil,
                lastNotifiedMomentID: nil
            )
        }
        Self.reloadWidgets()
    }

    /// Erases every cached moment file and the index that lists them.
    func eraseLocalMedia() {
        MomentIndex.shared.clear()
        StatusHistoryLog.shared.clear()
        // No grace window: an unlink erases everything, even seconds-old recordings.
        MomentStore.shared.prune(keeping: [], graceInterval: 0)
        MomentStore.clearThumbnailCache()
    }

    /// Wipes pairing, cached statuses and the whole moment history.
    func resetPairing() {
        eraseLocalMedia()
        clearPairing(keepingName: false)
    }

    // MARK: - Widgets

    /// `true` only inside the WidgetKit extension — deliberately not "any
    /// extension": the notification service still needs to reload widgets.
    static let isRunningInWidgetExtension: Bool = {
        guard let extensionInfo = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any],
              let point = extensionInfo["NSExtensionPointIdentifier"] as? String else {
            return false
        }
        return point == "com.apple.widgetkit-extension"
    }()

    /// Files moments in the history index, refreshes derived snapshot fields,
    /// and trims cached media.
    func record(_ moments: [Moment]) {
        guard !moments.isEmpty else { return }
        let all = MomentIndex.shared.insert(moments)
        refreshDerived(reloadWidgets: false)

        // Index keeps every entry; only recent files stay on disk — older
        // media is re-fetched from CloudKit on demand. A send still waiting to
        // upload has no cloud copy to re-fetch, so its files stay whatever its age.
        let keep = all.prefix(AppConfig.momentImageCacheLimit).map(\.id)
            + all.filter { $0.fromMe && !$0.uploaded }.map(\.id)
        MomentStore.shared.prune(keeping: keep)
        Self.reloadWidgets()
    }

    func record(_ moment: Moment) {
        record([moment])
    }

    /// Recomputes snapshot fields derived from the history index; call whenever
    /// the index changes. The index is read *inside* the locked mutate: a list
    /// captured earlier can be applied after another process's newer one, and
    /// the widget would regress to an older moment.
    func refreshDerived(reloadWidgets: Bool = true) {
        mutate(reloadWidgets: reloadWidgets) { snapshot in
            Self.fillDerived(&snapshot, from: MomentIndex.shared.load())
        }
    }

    /// Same, from a list the caller already holds (tests and previews).
    func applyDerived(from all: [Moment], reloadWidgets: Bool = true) {
        mutate(reloadWidgets: reloadWidgets) { Self.fillDerived(&$0, from: all) }
    }

    /// `all` is the whole index, newest first.
    private static func fillDerived(_ snapshot: inout Snapshot, from all: [Moment]) {
        // Unconditional: each field must be able to return to nil when the
        // last moment in its direction is deleted.
        snapshot.latestPartnerMoment = all.first { !$0.fromMe }
        snapshot.latestOwnMoment = all.first { $0.fromMe }
        snapshot.latestPartnerVisualMoment = all.first { !$0.fromMe && !$0.isVoice }
        snapshot.unheardVoiceMemoCount = all
            .filter { !$0.fromMe && $0.isVoice && !$0.seen }
            .count
    }

    // MARK: - CloudKit change tokens

    /// Opaque per-zone `CKServerChangeToken`. Clearing it makes the next sync
    /// pull the entire zone (how a reinstall recovers history).
    func changeToken(for key: String) -> Data? {
        store.data(forKey: "changeToken-\(key)")
    }

    func setChangeToken(_ data: Data?, for key: String) {
        store.setData(data, forKey: "changeToken-\(key)")
    }

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        // A reload from inside the widget process would re-enter the timeline
        // provider; WidgetKit already refreshes after interactive intents.
        guard !isRunningInWidgetExtension else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.momentWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.nudgeWidgetKind)
        #endif
    }

    // MARK: - Codable plumbing

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder.shared.decode(type, from: data)
        } catch {
            log.error("Failed to decode \(String(describing: type)): \(error.localizedDescription)")
            // Preserve the bytes: the caller falls back to an empty value, and the
            // next write would otherwise persist that loss over recoverable data.
            store.setData(data, forKey: "\(key).corrupt")
            return nil
        }
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            store.setData(try JSONEncoder.shared.encode(value), forKey: key)
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
