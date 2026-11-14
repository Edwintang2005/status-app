import Foundation
import os

#if canImport(WidgetKit)
import WidgetKit
#endif

/// App Group state shared between the app and its extensions (widget, notification
/// service, expanded banner, share sheet).
/// File-backed, not `UserDefaults` — see `GroupFileStore` for why.
/// `@unchecked`: all state is the key-value store (internally locked), the
/// decoded-value cache (under `decodedLock`) and the cross-process locks, so
/// any thread or actor may call in.
final class SharedStore: @unchecked Sendable {
    static let shared = SharedStore()

    /// The store's plumbing (`store`, `log`, `decode`, the `StoreKey` subscript)
    /// is internal for its own extension files, never for callers.
    let store: GroupKeyValueStore
    let log = Logger(subsystem: AppConfig.appGroupID, category: "SharedStore")
    /// Decoded values by the bytes they came from: comparing bytes is far
    /// cheaper than decoding them again, and any other writer changes them.
    private var decoded: [String: (data: Data, value: Any)] = [:]
    private let decodedLock = NSLock()

    /// A stored value's name; the JSON ones carry their type (`StoreKey`), so a
    /// getter and setter can't disagree. Plain names are raw bytes kept as they were.
    enum Key {
        static let snapshot = StoreKey<Snapshot>("snapshot")
        static let pairing = StoreKey<PairingInfo>("pairing")
        static let inviteClosed = "inviteClosed"
        static let inviteURL = "inviteURL"
        static let readReceipts = "readReceiptsEnabled"
        static let termsVersion = "acceptedTermsVersion"
        static let contentFilter = "contentFilterEnabled"
        static let hiddenMoments = StoreKey<Set<String>>("hiddenMomentIDs")
        static let pendingMomentDeletions = StoreKey<Set<String>>("pendingMomentDeletions")
        static let hiddenStatusAt = StoreKey<Date>("hiddenPartnerStatusAt")
        static let blockedOwners = StoreKey<Set<String>>("blockedOwnerRecordNames")
        static let anniversaryPrompt = "anniversaryPromptPending"
        static let unreadable = StoreKey<UnreadableTally>("unreadableRecords")
        static let zoneGone = StoreKey<Date>("zoneGoneSeenAt")
        static let fetchThrottledUntil = StoreKey<Date>("fetchThrottledUntil")
        static let shareCheckedAt = StoreKey<Date>("shareCheckedAt")
        static let lastPairing = StoreKey<PairingInfo>("lastPairing")
        static let closeLinkPromptDismissed = "closeLinkPromptDismissed"
        static let widgetTipDismissed = "widgetTipDismissed"
        static let recapNoticeDismissed = StoreKey<Int>("recapNoticeDismissed")
        static let partnerLeftNoticeDismissed = StoreKey<Date>("partnerLeftNoticeDismissed")
        static let subscriptionsVerified = StoreKey<Date>("subscriptionsVerifiedAt")
        static let widgetReloadRequestedAt = StoreKey<Date>("widgetReloadRequestedAt")
        static let verifiedAccount = StoreKey<VerifiedAccount>("verifiedAccount")
        static let nudgeRecordCache = StoreKey<NudgeRecordCache>("nudgeRecordCache")
        static let statusRecordCache = StoreKey<StatusRecordCache>("statusRecordCache")
        static let wholePushID = "wholePushID"
        static let lastPushID = "lastPushID"
        static let subscriptionCleanup = StoreKey<SubscriptionCleanup>("subscriptionCleanup")
        static let milestoneReminders = "milestoneRemindersEnabled"
        static let notificationPreferences = StoreKey<NotificationPreferences>("notificationPreferences")
        static let notificationsNoticeDismissed = "notificationsNoticeDismissed"
        static let cameraSettings = StoreKey<CameraSettings>("cameraSettings")
        static let lastBannerPass = StoreKey<BannerPass>("lastBannerPass")
        static let lastWidgetRun = StoreKey<WidgetRun>("lastWidgetRun")
        static let crashReports = StoreKey<[CrashReport]>("crashReports")
        static let layoutGlitches = StoreKey<[LayoutGlitch]>("layoutGlitches")
        static let shareUploadClaims = StoreKey<[String: Date]>("shareUploadClaims")
        static let historyCoverage = StoreKey<Int>("historyCoverage")
        static let shareLaunches = StoreKey<[ShareLaunch]>("shareLaunches")
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
        get { self[Key.snapshot] ?? .empty }
        set { self[Key.snapshot] = newValue }
    }

    /// The snapshot has writers in five processes (the app and each extension);
    /// without this lock, concurrent read-modify-writes lose updates.
    private static let snapshotLock = CrossProcessLock(name: "snapshot.lock")

    /// Locked read–modify–write plus a widget reload. A snapshot that exists
    /// but can't be read is left alone — the body would start from empty and
    /// save that over every watermark — and the change is dropped.
    @discardableResult
    func mutate(reloadWidgets: Bool = true, _ body: (inout Snapshot) -> Void) -> Snapshot {
        let outcome = Self.snapshotLock.withLock { () -> (Snapshot, Bool)? in
            if case .unreadable = store.storedValue(forKey: Key.snapshot.name) { return nil }
            let before = snapshot
            var current = before
            body(&current)
            // Unchanged: no write (it would make every other process re-read the
            // file) and no widget reload — nothing a widget draws moved.
            guard current != before else { return (current, false) }
            snapshot = current
            return (current, true)
        }
        guard let outcome else {
            log.error("Snapshot exists but can't be read; nothing written.")
            return snapshot
        }
        let (result, changed) = outcome
        if changed, reloadWidgets { requestWidgetReload() }
        return result
    }

    // MARK: - Pairing

    var pairing: PairingInfo? {
        get { self[Key.pairing] }
        set { self[Key.pairing] = newValue }
    }

    enum PairingState {
        case paired(PairingInfo)
        case unpaired
        /// The file is there but can't be read (before first unlock, an I/O error):
        /// not knowing isn't "unlinked", or a partner's push reads as from a space we left.
        case unreadable
    }

    var pairingState: PairingState {
        if case .unreadable = store.storedValue(forKey: Key.pairing.name) { return .unreadable }
        return pairing.map(PairingState.paired) ?? .unpaired
    }

    /// The pairing or the snapshot can't be read (before first unlock): what's
    /// drawn from them would be the empty, unlinked look.
    var isLockedOut: Bool {
        if case .unreadable = pairingState { return true }
        return store.storedValue(forKey: Key.snapshot.name) == .unreadable
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
        get { self[Key.hiddenMoments] ?? [] }
        set { self[Key.hiddenMoments] = newValue }
    }

    /// Own moments deleted here whose record iCloud hasn't confirmed gone
    /// (`Outbox.sendDeletions`): already off this phone, and kept out of every
    /// delta like reported ones until then. Written only by the app.
    var pendingMomentDeletions: Set<String> {
        get { self[Key.pendingMomentDeletions] ?? [] }
        set { self[Key.pendingMomentDeletions] = newValue }
    }

    /// `wordsAt` of a reported partner status (an older report's `updatedAt`);
    /// its text is never shown while that status is current. Cleared with the pairing.
    var hiddenPartnerStatusAt: Date? {
        get { self[Key.hiddenStatusAt] }
        set { self[Key.hiddenStatusAt] = newValue }
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
        get { self[Key.zoneGone] }
        set { self[Key.zoneGone] = newValue }
    }

    /// iCloud asked every process to slow its change fetches until then
    /// (`SendFailure.throttled`): the app's automatic fetches and the widget's wait
    /// it out; pull-to-refresh and the notification service's fetch don't.
    var fetchThrottledUntil: Date? {
        get { self[Key.fetchThrottledUntil] }
        set { self[Key.fetchThrottledUntil] = newValue }
    }

    /// Whether automatic fetches wait now; a stamp over `throttleMaxDelay` ahead is a clock change, not iCloud.
    func fetchWaitsOutThrottle(now: Date = Date()) -> Bool {
        guard let until = fetchThrottledUntil else { return false }
        return now < until && until.timeIntervalSince(now) <= AppConfig.throttleMaxDelay
    }

    /// The pairing this device was last cut loose from (`clearPairing(keepingName:)`),
    /// so re-accepting the *same* zone — a partner evicted by the close handshake
    /// tapping the link again — can keep its unsent media instead of wiping.
    var lastPairing: PairingInfo? {
        get { self[Key.lastPairing] }
        set { self[Key.lastPairing] = newValue }
    }

    /// CloudKit user record names of blocked people; their invites are refused.
    /// Survives unlink and "start over" — a block is meant to stick.
    var blockedOwnerRecordNames: Set<String> {
        get { self[Key.blockedOwners] ?? [] }
        set { self[Key.blockedOwners] = newValue }
    }

    /// Owner side: cached "invite link revoked" flag so `CloudSync` stops
    /// re-checking a closed share; the share's `publicPermission` is the truth.
    var inviteClosed: Bool {
        get { store.bool(forKey: Key.inviteClosed) }
        set { store.setBool(newValue, forKey: Key.inviteClosed) }
    }

    /// The owner's last look at who is on the share, kept across launches so a
    /// closed link isn't re-checked on every cold launch.
    var shareCheckedAt: Date? {
        get { self[Key.shareCheckedAt] }
        set { self[Key.shareCheckedAt] = newValue }
    }

    /// Owner side: cached invite link so Settings can show it instantly and
    /// offline; `CloudSync.shareCheck()` is the truth.
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

    /// Owner side: the home card asking to close the invite link once the
    /// partner is in was waved away. Per pairing — `clearPairing` resets it.
    var closeLinkPromptDismissed: Bool {
        get { store.bool(forKey: Key.closeLinkPromptDismissed) }
        set { store.setBool(newValue, forKey: Key.closeLinkPromptDismissed) }
    }

    /// When this device last confirmed its push subscriptions with the server,
    /// so launch re-asserts them daily rather than every time. Per pairing.
    var subscriptionsVerifiedAt: Date? {
        get { self[Key.subscriptionsVerified] }
        set { self[Key.subscriptionsVerified] = newValue }
    }

    /// The home card on adding the lock-screen widget was dismissed, or a
    /// widget was seen installed. Per device, and kept across unlinks.
    var widgetTipDismissed: Bool {
        get { store.bool(forKey: Key.widgetTipDismissed) }
        set { store.setBool(newValue, forKey: Key.widgetTipDismissed) }
    }

    /// The cap a complete sweep of the zone last filled the index to
    /// (`HistoryCoverage`); `owed` from any token clear until the sweep ends.
    var historyCoverage: Int? {
        get { self[Key.historyCoverage] }
        set { self[Key.historyCoverage] = newValue }
    }

    /// Sends the share sheet started, by moment id: the app's retry pass,
    /// deletes and the fresh start's clear leave them alone while
    /// `ShareIntake.isClaimed`. Written only by the sheet, one at a time.
    var shareUploadClaims: [String: Date] {
        get { self[Key.shareUploadClaims] ?? [:] }
        set { self[Key.shareUploadClaims] = newValue }
    }

    /// The year whose Home recap card was waved away (or opened). Per device,
    /// kept across unlinks.
    var recapNoticeDismissed: Int? {
        get { self[Key.recapNoticeDismissed] }
        set { self[Key.recapNoticeDismissed] = newValue }
    }

    /// The `partnerLeftAt` whose Home notice was waved away; a later departure shows again.
    var partnerLeftNoticeDismissed: Date? {
        get { self[Key.partnerLeftNoticeDismissed] }
        set { self[Key.partnerLeftNoticeDismissed] = newValue }
    }

    /// Opt-in local reminders on milestone mornings (`MilestoneReminderPlan`).
    /// Off by default, per device.
    var milestoneRemindersEnabled: Bool {
        get { store.data(forKey: Key.milestoneReminders).map { $0.first == 1 } ?? false }
        set { store.setData(Data([newValue ? 1 : 0]), forKey: Key.milestoneReminders) }
    }

    /// How loudly each kind of partner notification arrives here. Per device:
    /// an unlink keeps it.
    var notificationPreferences: NotificationPreferences {
        get { self[Key.notificationPreferences] ?? NotificationPreferences() }
        set { self[Key.notificationPreferences] = newValue }
    }

    /// The camera's last camera, flash and timer, per device. Not pairing
    /// state: an unlink keeps it.
    var cameraSettings: CameraSettings {
        get { self[Key.cameraSettings] ?? CameraSettings() }
        set { self[Key.cameraSettings] = newValue }
    }

    /// The signed-in account's user record name as a process last verified it,
    /// so a cold extension can skip the lookup round trip inside its budget.
    /// Trusted only for `CloudSync.accountCacheLifetime`, like the per-process
    /// cache, and cleared on an account change.
    struct VerifiedAccount: Codable, Equatable, Sendable {
        var name: String
        var verifiedAt: Date
    }

    var verifiedAccount: VerifiedAccount? {
        get { self[Key.verifiedAccount] }
        set { self[Key.verifiedAccount] = newValue }
    }

    /// Our nudge record's system fields and count as last saved or fetched, so
    /// the lock-screen heart saves without a fetch first (`CloudSync.saveNudge`).
    /// A stale copy only costs a conflict, which hands back the server's.
    struct NudgeRecordCache: Codable, Equatable, Sendable {
        var systemFields: Data
        var count: Int
    }

    var nudgeRecordCache: NudgeRecordCache? {
        get { self[Key.nudgeRecordCache] }
        set { self[Key.nudgeRecordCache] = newValue }
    }

    /// Our status record's system fields and what it held when last saved or
    /// fetched, so a status save skips the fetch (`CloudSync.saveStatus`). A
    /// stale copy only costs a conflict, which falls back to the fetch.
    struct StatusRecordCache: Codable, Equatable, Sendable {
        var systemFields: Data
        var payload: StatusPayload
    }

    var statusRecordCache: StatusRecordCache? {
        get { self[Key.statusRecordCache] }
        set { self[Key.statusRecordCache] = newValue }
    }

    /// The last push whose refresh in the notification service took the whole
    /// delta, readable (`RefreshResult.isWholeDelta`): the open app showing
    /// that banner has nothing left to fetch for it.
    var wholePushID: String? {
        get { store.data(forKey: Key.wholePushID).flatMap { String(data: $0, encoding: .utf8) } }
        set { store.setData(newValue.flatMap { $0.data(using: .utf8) }, forKey: Key.wholePushID) }
    }

    /// The last push the notification service started on. Unequal to
    /// `wholePushID`, its pass failed, ran out of time or took part of a delta.
    var lastPushID: String? {
        get { store.data(forKey: Key.lastPushID).flatMap { String(data: $0, encoding: .utf8) } }
        set { store.setData(newValue.flatMap { $0.data(using: .utf8) }, forKey: Key.lastPushID) }
    }

    /// The old pairing's subscriptions may still be registered: an unlink that
    /// never reached iCloud (an offline block, a local-only reset) left them, and
    /// the ex's every write would keep pushing here. Retried while unpaired
    /// (`AppModel.cleanUpSubscriptionsIfNeeded`) until both databases confirm.
    struct SubscriptionCleanup: Codable, Equatable, Sendable {
        /// The account the subscriptions belong to; `nil` for a legacy pairing.
        var userRecordName: String?
        var since: Date
    }

    var subscriptionCleanup: SubscriptionCleanup? {
        get { self[Key.subscriptionCleanup] }
        set { self[Key.subscriptionCleanup] = newValue }
    }

    /// Which "notifications are off" notice Home's card was waved away for —
    /// per device; `NotificationsNotice.reconcile` forgets it once that changes.
    var notificationsNoticeDismissed: NotificationsNotice? {
        get { store.data(forKey: Key.notificationsNoticeDismissed)
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(NotificationsNotice.init(rawValue:)) }
        set { store.setData(newValue?.rawValue.data(using: .utf8), forKey: Key.notificationsNoticeDismissed) }
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
            closeLinkPromptDismissed = false
            hiddenPartnerStatusAt = nil
            anniversaryPromptPending = false
            zoneGoneSeenAt = nil
            shareCheckedAt = nil
            subscriptionsVerifiedAt = nil
            nudgeRecordCache = nil
            statusRecordCache = nil
            store.setData(nil, forKey: Key.unreadable.name)
            clearChangeTokens()
            var fresh = Snapshot.empty
            if let name, !name.isEmpty { fresh.mine = .initial(displayName: name) }
            snapshot = fresh
            // Preserved corrupt bytes are the ex's data too.
            for key in [Key.snapshot.name, Key.pairing.name, Key.lastPairing.name, Key.hiddenStatusAt.name,
                        Key.unreadable.name, Key.pendingMomentDeletions.name] {
                store.setData(nil, forKey: "\(key).corrupt")
            }
            decodedLock.withLock { decoded.removeAll() }
        }
        requestWidgetReload()
    }

    /// Erases every cached moment file and the index that lists them. With
    /// `keepingPendingUploads`, own sends that never reached CloudKit survive —
    /// they exist nowhere else, and a re-pairing to the same zone re-sends them.
    func eraseLocalMedia(keepingPendingUploads: Bool = false) {
        CloudStores(shared: self, index: .shared, media: .shared, statusLog: .shared, recaps: .shared)
            .eraseLocalMedia(keepingPendingUploads: keepingPendingUploads)
    }

    /// Wipes pairing, cached statuses and the whole moment history.

    // MARK: - CloudKit change tokens

    /// Opaque per-zone `CKServerChangeToken`. Clearing it makes the next sync
    /// pull the entire zone (how a reinstall recovers history).
    func changeToken(for key: String) -> Data? {
        store.data(forKey: "changeToken-\(key)")
    }

    func setChangeToken(_ data: Data?, for key: String) {
        store.setData(data, forKey: "changeToken-\(key)")
    }

    private static let tokenLock = CrossProcessLock(name: "token.lock")

    /// Writes `data` only if `allowed` says so of the token stored now, both under
    /// one cross-process lock: a refresh's compare-and-swap (`TokenAdvancePolicy`).
    func setChangeToken(_ data: Data, for key: String, if allowed: (Data?) -> Bool) -> Bool {
        Self.tokenLock.withLock {
            guard allowed(changeToken(for: key)) else { return false }
            setChangeToken(data, for: key)
            return true
        }
    }

    /// One token per database: the owner's zone lives in `private`, the participant's in `shared`.
    static func changeTokenKey(for role: PairRole) -> String {
        role == .owner ? "private" : "shared"
    }

    func clearChangeTokens() {
        for role in [PairRole.owner, .participant] { setChangeToken(nil, for: Self.changeTokenKey(for: role)) }
        // The next fetch sweeps the whole zone; until it ends, the index may stop short.
        historyCoverage = HistoryCoverage.owed
    }

    // MARK: - Codable plumbing

    subscript<Value: Codable>(key: StoreKey<Value>) -> Value? {
        get { decode(Value.self, forKey: key.name) }
        set { encodeOptional(newValue, forKey: key.name) }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        if let hit = decodedLock.withLock({ decoded[key] }), hit.data == data, let value = hit.value as? T {
            return value
        }
        do {
            let value = try JSONDecoder.shared.decode(type, from: data)
            decodedLock.withLock { decoded[key] = (data, value) }
            return value
        } catch {
            log.error("Failed to decode \(String(describing: type)): \(error.localizedDescription)")
            // Preserve the bytes: the caller falls back to an empty value, and the
            // next write would otherwise persist that loss over recoverable data.
            let firstSighting = store.data(forKey: "\(key).corrupt") != data
            store.setData(data, forKey: "\(key).corrupt")
            // Like the index and the log: a blank snapshot (both statuses) refills
            // only from a full fetch — once, not on every read until it's rewritten.
            if firstSighting, key == Key.snapshot.name { clearChangeTokens() }
            return nil
        }
    }

    func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder.shared.encode(value)
            // The same bytes again: a rewrite would only make every process re-read it.
            guard store.data(forKey: key) != data else { return }
            store.setData(data, forKey: key)
        } catch {
            log.error("Failed to encode \(String(describing: T.self)): \(error.localizedDescription)")
        }
    }

    func encodeOptional<T: Encodable>(_ value: T?, forKey key: String) {
        if let value {
            encode(value, forKey: key)
        } else {
            store.setData(nil, forKey: key)
        }
    }
}

/// A JSON-stored value's name and type (`SharedStore.Key`).
struct StoreKey<Value: Codable>: Sendable {
    let name: String
    init(_ name: String) { self.name = name }
}

extension JSONEncoder {
    static let shared: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable bytes for equal values, so an unchanged write is seen as one.
        encoder.outputFormatting = .sortedKeys
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
