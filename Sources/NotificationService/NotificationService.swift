import CloudKit
import UserNotifications
import os

/// Handles CloudKit's visible pushes (which survive force-quit) in the ~30s
/// mutable-content window: fetch, decrypt on-device, update the App Group and
/// widget, and replace the generic wording — CloudKit can't read the encrypted
/// fields. What the banner says is `PushBannerPolicy`'s; this only applies it.
/// `@unchecked`: the expiry callback and the enrich task race on delivery and
/// on `fallback`, which `deliveryLock` serialises; the rest is set before the task starts.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let log = Logger(subsystem: AppConfig.appGroupID, category: "NotificationService")

    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// What expiry delivers: CloudKit's version until the banner is worded, then
    /// that wording — a copy, never the content `enrich` is still changing.
    private var fallback: UNNotificationContent?
    private var work: Task<Void, Never>?
    private let deliveryLock = NSLock()
    private var delivered = false
    /// How this pass went, for Diagnostics; recorded by whichever delivery wins.
    private var outcome = SharedStore.BannerPass.Outcome.timedOut
    private var outcomeDetail: String?
    private var receivedAt = Date()
    /// One widget reload per push, however many the refresh asks for.
    private var reloadHold: SharedStore.WidgetReloadHold?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        receivedAt = Date()
        let push = PushBannerPolicy.Push(
            subscriptionID: CKNotification(fromRemoteNotificationDictionary: request.content.userInfo)?.subscriptionID)
        // Category up front, so every exit — enriched, unclaimed, refresh failed,
        // or the expiry fallback — carries the banner actions.
        let fallback = request.content.mutableCopy() as? UNMutableNotificationContent
        fallback?.categoryIdentifier = push.category
        // This phone's preference before anything is read: an expiry delivers no louder.
        let preferences = SharedStore.shared.notificationPreferences
        fallback?.limit(to: preferences.level(for: push))
        push.markUnworded(fallback)
        self.fallback = fallback
        reloadHold = SharedStore.shared.holdWidgetReloads()
        // Handed to the task; only the category is set on it here first.
        nonisolated(unsafe) let original = request.content
        nonisolated(unsafe) let mutable = original.mutableCopy() as? UNMutableNotificationContent
        mutable?.categoryIdentifier = push.category
        mutable?.limit(to: preferences.level(for: push))

        let hold = reloadHold
        let id = request.identifier
        // Before anything can fail: the open app fetches until a pass of this push takes it whole.
        SharedStore.shared.lastPushID = id
        work = Task { [weak self] in
            guard let self else {
                hold?.release(widgetNeedsFetch: true)
                return
            }
            let enriched = await self.enrich(mutable, push: push, userInfo: original.userInfo, id: id)
            self.deliver(enriched ?? original)
        }
    }

    /// Out of time — show the worded banner if there is one, else CloudKit's.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        // The refresh may have landed records before the deadline — reload anyway,
        // and let the widget fetch: this pass may not have finished.
        reloadHold?.release(widgetNeedsFetch: true)
        deliveryLock.lock()
        let fallback = self.fallback
        deliveryLock.unlock()
        if let fallback {
            deliver(fallback)
        }
    }

    /// Exactly one delivery, whichever of the Task and the expiry gets here first.
    private func deliver(_ content: UNNotificationContent) {
        deliveryLock.lock()
        let first = !delivered
        delivered = true
        let pass = SharedStore.BannerPass(at: receivedAt, outcome: outcome,
                                          seconds: Date().timeIntervalSince(receivedAt), detail: outcomeDetail)
        deliveryLock.unlock()
        guard first else { return }
        // Before the hand-over: iOS may reclaim the process the moment it has the banner.
        SharedStore.shared.lastBannerPass = pass
        contentHandler?(content)
    }

    private func note(_ outcome: SharedStore.BannerPass.Outcome, _ detail: String? = nil) {
        deliveryLock.lock()
        self.outcome = outcome
        outcomeDetail = detail
        deliveryLock.unlock()
    }

    /// An exit before any plan (`PushBannerPolicy.Bypass`), applied and noted.
    private func bypass(_ bypass: PushBannerPolicy.Bypass, _ content: UNMutableNotificationContent,
                        push: PushBannerPolicy.Push) -> UNNotificationContent {
        let (outcome, detail) = bypass.apply(to: content, push: push)
        note(outcome, detail)
        return content
    }

    private func setFallback(_ content: UNMutableNotificationContent) {
        let copy = content.copy() as? UNNotificationContent
        deliveryLock.lock()
        if let copy { fallback = copy }
        deliveryLock.unlock()
    }

    // MARK: - Enrichment

    private func enrich(_ content: UNMutableNotificationContent?,
                        push: PushBannerPolicy.Push,
                        userInfo: [AnyHashable: Any],
                        id: String) async -> UNNotificationContent? {
        // Always release the reload hold (a reused process's reloads stay silenced
        // otherwise); the widget fetches again unless the refresh completed.
        var widgetNeedsFetch = true
        defer { reloadHold?.release(widgetNeedsFetch: widgetNeedsFetch) }
        guard let content else { return nil }
        let pairing = await MainActor.run(body: { SharedStore.shared.pairingState })
        if let early = PushBannerPolicy.Bypass(
            isCloudKitPush: CKNotification(fromRemoteNotificationDictionary: userInfo) != nil, pairing: pairing) {
            widgetNeedsFetch = early.widgetNeedsFetch
            return bypass(early, content, push: push)
        }

        let result: RefreshResult
        // Downloaded only once the banner is worded: it no longer waits on a picture.
        let media: CloudSync.PendingMedia
        do {
            (result, media) = try await CloudSync.shared.refreshDeferringMedia()
        } catch {
            log.error("Refresh failed in service extension: \(error.localizedDescription)")
            let failed = PushBannerPolicy.Bypass(after: error)
            widgetNeedsFetch = failed.widgetNeedsFetch
            return bypass(failed, content, push: push)
        }
        // Records owed recently (this service never retries them) leave the widget
        // and the open app something to fetch, like the rest of a batch.
        let owesRecords = await MainActor.run {
            SharedStore.shared.unreadableTally.heldSince
                .map { Date().timeIntervalSince($0) < AppFetchPolicy.owedRecentlyWindow } ?? false
        }
        widgetNeedsFetch = result.incomplete || owesRecords
        // Filed whether or not the banner gets worded in time.
        if result.isWholeDelta, !owesRecords { await MainActor.run { SharedStore.shared.wholePushID = id } }

        // Out of time: the expiry fallback is (or is about to be) delivered, and
        // a claim now would mark announced an event whose rich banner never shows.
        if Task.isCancelled { return content }
        let (row, plan, carried) = await MainActor.run { () -> (PushBannerPolicy.Row, PushBannerPolicy.Plan, Moment?) in
            let reportedAt = SharedStore.shared.hiddenPartnerStatusAt
            var row = PushBannerPolicy.Row.other
            var plan = PushBannerPolicy.Plan.unchanged
            var carried: Moment?
            // Check-and-claim in one `mutate` under the cross-process lock, so
            // concurrent instances and the app never both announce one event.
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                (row, plan) = PushBannerPolicy.decideRow(push, result: result, reportedAt: reportedAt, in: &$0)
                carried = PushBannerPolicy.carriedMoment(push, in: &$0)
            }
            return (row, plan, carried)
        }
        let level = SharedStore.shared.notificationPreferences
            .level(for: push, momentKinds: result.newPartnerMoments.map(\.kind) + result.heldPartnerMomentKinds
                   + [plan.attachment?.kind].compactMap { $0 })
        plan.limited(to: level).apply(to: content)
        if plan.title == nil, plan.body == nil {
            push.markUnworded(content)
            let why = result.incomplete ? "one batch of many"
                : result.unreadableRecordNames.isEmpty ? nil
                : "\(result.unreadableRecordNames.count) record(s) unreadable"
            // Which row of `PushBannerPolicy` decided it, for Diagnostics.
            note(.unworded, [row.rawValue, why].compactMap { $0 }.joined(separator: ", "))
        } else {
            note(.worded, row.rawValue)
        }
        // Stamped before the fallback: an expiry mid-fetch still leaves a later pass the picture to add.
        if plan.attachment != nil { content.userInfo[BannerSubject.wantsAttachmentKey] = true }
        // Worded and claimed: from here on expiry delivers these words, not
        // CloudKit's — the claim stands, so nothing would ever re-announce it.
        setFallback(content)
        // Earlier banners, beside this push's downloads rather than after them:
        // the banner waits on the slower of the two, not both.
        async let tidied: Void = tidyUp(incoming: plan.subject, caughtUp: result.isWholeDelta)
        // The delta's pictures, now that the words are safe: a carried moment from
        // this delta is posted with its own. Skipped or cut short, the widget's
        // next run fetches the one it draws.
        if await !prefetch(media) { widgetNeedsFetch = true }
        // Claimed too, so posted now — after the fallback, which no wait may precede.
        if let carried { await announce(carried: carried) }
        if let moment = plan.attachment { await attach(moment, to: content) }
        await tidied
        return content
    }

    /// This push's own picture. The refresh fetched at most the widget's thumbnail;
    /// pull only what the banner attaches — the thumbnail, or a memo's recording —
    /// and only while there's time left for the words to go out anyway.
    private func attach(_ moment: Moment, to content: UNMutableNotificationContent) async {
        var attachment = MomentAttachment.make(for: moment, suffix: "push")
        if attachment == nil,
           let deadline = PushBannerPolicy.attachmentDeadline(elapsed: Date().timeIntervalSince(receivedAt)) {
            try? await withDeadline(deadline) { try await CloudSync.shared.fetchAttachment(for: moment) }
            attachment = MomentAttachment.make(for: moment, suffix: "push")
        }
        if let attachment {
            content.attachments = [attachment]
            content.userInfo[BannerSubject.wantsAttachmentKey] = nil
        }
    }

    /// The delta's pictures, once the banner is worded, within what's left of the
    /// window. - Returns: `false` when skipped or cut short by it.
    private func prefetch(_ media: CloudSync.PendingMedia) async -> Bool {
        guard !Task.isCancelled,
              let within = PushBannerPolicy.attachmentDeadline(elapsed: Date().timeIntervalSince(receivedAt)) else {
            return false
        }
        return await media(within)
    }

    /// Earlier banners this pass can now complete — reworded, given their
    /// picture, withdrawn — since the phone may have been locked when they came.
    /// Bounded, and skipped once out of time: this push's banner goes out regardless.
    private func tidyUp(incoming: BannerSubject?, caughtUp: Bool) async {
        guard !Task.isCancelled else { return }
        try? await withDeadline(3) { await BannerUpkeep.run(incoming: incoming, caughtUp: caughtUp) }
    }

    /// Its own banner beside this push's, as the app would post it; a picture
    /// not yet on disk is left for `BannerUpkeep` to attach.
    private func announce(carried moment: Moment) async {
        let name = await MainActor.run { SharedStore.shared.snapshot.moderatedPartnerName }
        let content = MomentBanner.content(for: moment, from: name)
        content.limit(to: SharedStore.shared.notificationPreferences.level(forMoment: moment.kind))
        if let attachment = MomentAttachment.make(for: moment, suffix: "carried") {
            content.attachments = [attachment]
        } else {
            content.userInfo[BannerSubject.wantsAttachmentKey] = true
        }
        let request = UNNotificationRequest(identifier: MomentBanner.identifier(for: moment.id),
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
