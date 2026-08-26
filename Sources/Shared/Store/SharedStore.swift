import Foundation
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// The App Group is the only channel between the app process and the widget
/// extension process. Both read the same `Snapshot`; only the app normally
/// writes it (the exception is `SendNudgeIntent`, which bumps the cooldown).
///
/// Backed by files in the group container rather than by `UserDefaults` — see
/// `GroupFileStore` for the (thoroughly unpleasant) reason why.
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
                store.setData(nil, forKey: Key.pairing)
            }
        }
    }

    var hasRequestedNotifications: Bool {
        get { store.bool(forKey: Key.notificationsRequested) }
        set { store.setBool(newValue, forKey: Key.notificationsRequested) }
    }

    /// Owner side: whether the invite link has been revoked, so `CloudSync`
    /// stops asking the server about a share it already closed. Local memory of
    /// a server fact — the share's `publicPermission` is the truth, this only
    /// keeps a settled pairing from re-checking it on every refresh.
    var inviteClosed: Bool {
        get { store.bool(forKey: Key.inviteClosed) }
        set { store.setBool(newValue, forKey: Key.inviteClosed) }
    }

    /// Owner side: the invite link handed back by `createPairInvite`, kept so
    /// it can be shared again later.
    ///
    /// A cache of a server fact, like `inviteClosed` — `CloudSync
    /// .inviteState()` is the truth. Held here so Settings can show the
    /// link the instant it opens, and offline, rather than only after a
    /// round trip.
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

    /// Forgets the link, both partners' statuses and the sync cursors.
    ///
    /// `keepingName` decides which of the two endings this is: unlinking keeps
    /// the name you chose so pairing again doesn't start with paperwork, while
    /// starting over forgets it and puts the app back where a fresh install
    /// leaves it — see `AppModel.unlink(startingOver:)`.
    func clearPairing(keepingName: Bool) {
        let name = keepingName
            ? snapshot.mine?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        pairing = nil
        // The next pairing gets a new share with a new link, which starts open.
        inviteClosed = false
        inviteURL = nil
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
        Self.reloadWidgets()
    }

    /// Every photo, drawing and voice memo either of you sent, and the index
    /// that lists them. Separate from `clearPairing` only because the two are
    /// worth naming separately at the call site; both endings do both.
    func eraseLocalMedia() {
        MomentIndex.shared.clear()
        MomentStore.shared.prune(keeping: [])
    }

    /// Wipes pairing, cached statuses and the whole moment history.
    func resetPairing() {
        eraseLocalMedia()
        clearPairing(keepingName: false)
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
    /// snapshot if it's the newest in its direction, and trims cached media.
    func record(_ moments: [Moment]) {
        guard !moments.isEmpty else { return }
        let all = MomentIndex.shared.insert(moments)
        applyDerived(from: all, reloadWidgets: false)

        // Keep every entry in the index but only recent files on disk; older
        // ones are re-fetched from CloudKit when the gallery reaches them.
        let keep = all.prefix(AppConfig.momentImageCacheLimit).map(\.id)
        MomentStore.shared.prune(keeping: keep)
        Self.reloadWidgets()
    }

    func record(_ moment: Moment) {
        record([moment])
    }

    /// Recomputes every snapshot field that is really a summary of the history
    /// index, and must therefore be refreshed whenever the index changes —
    /// on arrival *and* when something is marked as looked-at or heard.
    ///
    /// `moments` must be the whole index, newest first, as returned by
    /// `MomentIndex`.
    func applyDerived(from all: [Moment], reloadWidgets: Bool = true) {
        mutate(reloadWidgets: reloadWidgets) { snapshot in
            if let newestTheirs = all.first(where: { !$0.fromMe }) {
                snapshot.latestPartnerMoment = newestTheirs
            }
            if let newestMine = all.first(where: { $0.fromMe }) {
                snapshot.latestOwnMoment = newestMine
            }
            // Not conditional, unlike the two above: the widget shows this
            // one, and it has to be able to go back to `nil` when the only
            // picture is deleted.
            snapshot.latestPartnerVisualMoment = all.first { !$0.fromMe && !$0.isVoice }
            snapshot.unheardVoiceMemoCount = all
                .filter { !$0.fromMe && $0.isVoice && !$0.seen }
                .count
        }
    }

    // MARK: - CloudKit change tokens

    /// Opaque per-zone `CKServerChangeToken`, so a sync only asks for what has
    /// changed. Clearing it makes the next sync pull the entire zone, which is
    /// how a reinstalled app recovers its whole history.
    func changeToken(for key: String) -> Data? {
        store.data(forKey: "changeToken-\(key)")
    }

    func setChangeToken(_ data: Data?, for key: String) {
        store.setData(data, forKey: "changeToken-\(key)")
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
        guard let data = store.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder.shared.decode(type, from: data)
        } catch {
            log.error("Failed to decode \(String(describing: type)): \(error.localizedDescription)")
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
