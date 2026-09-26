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
        static let inviteClosed = "inviteClosed"
        static let inviteURL = "inviteURL"
        static let readReceipts = "readReceiptsEnabled"
        static let termsVersion = "acceptedTermsVersion"
        static let contentFilter = "contentFilterEnabled"
        static let hiddenMoments = "hiddenMomentIDs"
        static let hiddenStatusAt = "hiddenPartnerStatusAt"
        static let blockedOwners = "blockedOwnerRecordNames"
        static let anniversaryPrompt = "anniversaryPromptPending"
        static let unreadable = "unreadableRecords"
        static let zoneGone = "zoneGoneSeenAt"
        static let lastPairing = "lastPairing"
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

    /// Owner side: the "when did you two begin?" prompt is owed — set when the
    /// zone is created, cleared once answered or skipped. Persisted so a kill
    /// between creating the link and the prompt doesn't lose it.
    var anniversaryPromptPending: Bool {
        get { store.bool(forKey: Key.anniversaryPrompt) }
        set { store.setBool(newValue, forKey: Key.anniversaryPrompt) }
    }

    /// When a refresh first found the shared zone missing. The self-unlink
    /// waits for a second sighting `AppConfig.zoneGoneConfirmation` later
    /// (`CloudSync.zoneGoneVerdict`); any successful fetch clears it.
    var zoneGoneSeenAt: Date? {
        get { decode(Date.self, forKey: Key.zoneGone) }
        set {
            if let newValue {
                encode(newValue, forKey: Key.zoneGone)
            } else {
                store.setData(nil, forKey: Key.zoneGone)
            }
        }
    }

    /// The pairing this device was last cut loose from (`clearPairing(keepingName:)`),
    /// so re-accepting the *same* zone — a partner evicted by the close handshake
    /// tapping the link again — can keep its unsent media instead of wiping.
    var lastPairing: PairingInfo? {
        get { decode(PairingInfo.self, forKey: Key.lastPairing) }
        set {
            if let newValue {
                encode(newValue, forKey: Key.lastPairing)
            } else {
                store.setData(nil, forKey: Key.lastPairing)
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

            // An unlink remembers where it came from; "start over" forgets it.
            lastPairing = keepingName ? pairing : nil
            pairing = nil
            // The next pairing gets a new share with a new link, which starts open.
            inviteClosed = false
            inviteURL = nil
            hiddenPartnerStatusAt = nil
            anniversaryPromptPending = false
            zoneGoneSeenAt = nil
            store.setData(nil, forKey: Key.unreadable)
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

    /// Erases every cached moment file and the index that lists them. With
    /// `keepingPendingUploads`, own sends that never reached CloudKit survive —
    /// they exist nowhere else, and a re-pairing to the same zone re-sends them.
    func eraseLocalMedia(keepingPendingUploads: Bool = false) {
        let kept = keepingPendingUploads ? MomentIndex.shared.retainPendingUploads() : []
        if !keepingPendingUploads { MomentIndex.shared.clear() }
        StatusHistoryLog.shared.clear()
        // No grace window: an unlink erases everything, even seconds-old recordings.
        MomentStore.shared.prune(keeping: kept.map(\.id), graceInterval: 0)
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
        // An unreadable index returned only this delta: pruning against it
        // would delete the media of everything else.
        guard !MomentIndex.shared.readFailed else { return }
        refreshDerived(reloadWidgets: false)

        // Index keeps every entry; only recent files stay on disk — older
        // media is re-fetched from CloudKit on demand. A send still waiting to
        // upload has no cloud copy to re-fetch, so its files stay whatever its age.
        // Thumbnails stay for the whole index: the library grid scrolls through them.
        let keep = all.prefix(AppConfig.momentImageCacheLimit).map(\.id)
            + all.filter { $0.fromMe && !$0.uploaded }.map(\.id)
        MomentStore.shared.prune(keeping: keep, thumbnailsFor: all.map(\.id))
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
            let all = MomentIndex.shared.load()
            // Unreadable reads as empty; the widget keeps what it last showed.
            guard !MomentIndex.shared.readFailed else { return }
            Self.fillDerived(&snapshot, from: all)
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

    // MARK: - Unreadable records (Diagnostics)

    /// Per-process count of records whose encrypted fields came back empty —
    /// the evidence for whether background processes lose decryption — plus the
    /// hold the app keeps over them (see `noteUnreadableRecords`).
    struct UnreadableTally: Codable, Equatable {
        var counts: [String: Int] = [:]
        var lastAt: Date?
        /// Record names the change token is currently being held for.
        var heldNames: [String] = []
        /// Separate app refreshes that found the same names unreadable.
        var heldStreak = 0
        var heldAt: Date?
        /// When the current hold began, by any process — how long the widget has
        /// been showing a stale snapshot (`WidgetReloadPolicy`).
        var heldSince: Date?
        /// Records the app gave up on and advanced past — gone until a full resync.
        var abandoned = 0

        init() {}

        private enum CodingKeys: String, CodingKey {
            case counts, lastAt, heldNames, heldStreak, heldAt, heldSince, abandoned
        }

        /// Hand-written: fields added after the first release fall back (invariant 5).
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            counts = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
            lastAt = try container.decodeIfPresent(Date.self, forKey: .lastAt)
            heldNames = try container.decodeIfPresent([String].self, forKey: .heldNames) ?? []
            heldStreak = try container.decodeIfPresent(Int.self, forKey: .heldStreak) ?? 0
            heldAt = try container.decodeIfPresent(Date.self, forKey: .heldAt)
            heldSince = try container.decodeIfPresent(Date.self, forKey: .heldSince)
            abandoned = try container.decodeIfPresent(Int.self, forKey: .abandoned) ?? 0
        }

        var summary: String {
            guard !counts.isEmpty else { return "none" }
            var parts = counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }
            if !heldNames.isEmpty { parts.append("holding \(heldNames.count) (\(heldStreak) app refresh\(heldStreak == 1 ? "" : "es"))") }
            if abandoned > 0 { parts.append("gave up on \(abandoned)") }
            let last = lastAt.map { " (last \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
            return parts.joined(separator: ", ") + last
        }
    }

    private static let tallyLock = CrossProcessLock(name: "unreadable.lock")

    var unreadableTally: UnreadableTally {
        decode(UnreadableTally.self, forKey: Key.unreadable) ?? UnreadableTally()
    }

    /// Records that a refresh skipped these records, and decides whether the
    /// change token should advance past them anyway. Holding is right while
    /// the process simply lacks the keys (a locked device's extensions), but a
    /// record nobody can ever read would pin the token — and the whole delta
    /// behind it — forever. So only the *app with the phone unlocked*, which has
    /// the keys, counts; after `AppConfig.unreadableHoldLimit` separate looks at
    /// the same names it gives up on them. Returns `true` to advance.
    @discardableResult
    func noteUnreadableRecords(_ names: [String], now: Date = Date()) -> Bool {
        guard !names.isEmpty else { return false }
        return Self.tallyLock.withLock {
            var tally = unreadableTally
            tally.counts[Self.processLabel, default: 0] += names.count
            tally.lastAt = now

            var advance = false
            if Self.processLabel == "app", Self.protectedDataAvailable {
                let sameRecords = Set(names).isSubset(of: tally.heldNames)
                if !sameRecords {
                    tally.heldStreak = 1
                    tally.heldAt = now
                } else if let held = tally.heldAt,
                          now.timeIntervalSince(held) >= AppConfig.unreadableHoldSpacing {
                    tally.heldStreak += 1
                    tally.heldAt = now
                }
                if tally.heldStreak >= AppConfig.unreadableHoldLimit {
                    advance = true
                    tally.abandoned += names.count
                    tally.heldStreak = 0
                    tally.heldAt = nil
                    tally.heldSince = nil
                    tally.heldNames = []
                    log.error("Giving up on \(names.count) record(s) that stayed unreadable across \(AppConfig.unreadableHoldLimit) refreshes; advancing the change token.")
                }
            }
            if !advance {
                // Every process notes what it saw; a superset from an extension
                // keeps the app's next (smaller) set counting as the same records.
                tally.heldNames = names
                if tally.heldSince == nil { tally.heldSince = now }
            }
            encode(tally, forKey: Key.unreadable)
            return advance
        }
    }

    /// A refresh read everything: whatever was being held has resolved.
    func clearUnreadableHold() {
        Self.tallyLock.withLock {
            var tally = unreadableTally
            guard !tally.heldNames.isEmpty || tally.heldStreak > 0 else { return }
            tally.heldNames = []
            tally.heldStreak = 0
            tally.heldAt = nil
            tally.heldSince = nil
            encode(tally, forKey: Key.unreadable)
        }
    }

    /// Kept current by the app from the protected-data notifications; a locked
    /// phone's background refresh must not count toward giving up. Extensions
    /// never give up regardless.
    nonisolated(unsafe) static var protectedDataAvailable = true

    /// Which of the three processes this is, for the tally above.
    static let processLabel: String = {
        guard let extensionInfo = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any],
              let point = extensionInfo["NSExtensionPointIdentifier"] as? String else {
            return "app"
        }
        return point == "com.apple.widgetkit-extension" ? "widget" : "notification service"
    }()

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
