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
        deliveryLock.unlock()
        guard first else { return }
        contentHandler?(content)
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
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return content }

        // Unpaired with the old subscriptions still registered (an offline block,
        // a local-only reset): never at full volume, never a heart to send back.
        guard await MainActor.run(body: { SharedStore.shared.pairing != nil }) else {
            widgetNeedsFetch = false
            apply(PushBannerPolicy.unpaired, to: content)
            return content
        }

        let result: RefreshResult
        do {
            result = try await CloudSync.shared.refresh()
        } catch SyncError.notPaired {
            // Unpaired, like the guard above: there's nothing for the widget to fetch.
            widgetNeedsFetch = false
            apply(PushBannerPolicy.unpaired, to: content)
            return content
        } catch {
            log.error("Refresh failed in service extension: \(error.localizedDescription)")
            return content
        }
        widgetNeedsFetch = result.incomplete
        // Filed whether or not the banner gets worded in time.
        if result.isWholeDelta { await MainActor.run { SharedStore.shared.wholePushID = id } }

        // Out of time: the expiry fallback is (or is about to be) delivered, and
        // a claim now would mark announced an event whose rich banner never shows.
        if Task.isCancelled { return content }
        // The banner's fallback only looks past the announced floor.
        let index = push == .moment ? momentCandidates() : []
        let plan = await MainActor.run { () -> PushBannerPolicy.Plan in
            let reportedAt = SharedStore.shared.hiddenPartnerStatusAt
            var plan = PushBannerPolicy.Plan.unchanged
            // Check-and-claim in one `mutate` under the cross-process lock, so
            // concurrent instances and the app never both announce one event.
            _ = SharedStore.shared.mutate(reloadWidgets: false) {
                plan = PushBannerPolicy.decide(push, result: result, index: index, reportedAt: reportedAt, in: &$0)
            }
            return plan
        }
        let level = SharedStore.shared.notificationPreferences
            .level(for: push, momentKinds: result.newPartnerMoments.map(\.kind) + result.heldPartnerMomentKinds)
        apply(plan.limited(to: level), to: content)
        // Stamped before the fallback: an expiry mid-fetch still leaves a later pass the picture to add.
        if plan.attachment != nil { content.userInfo[BannerSubject.wantsAttachmentKey] = true }
        // Worded and claimed: from here on expiry delivers these words, not
        // CloudKit's — the claim stands, so nothing would ever re-announce it.
        setFallback(content)
        // This push's own picture first; then earlier banners (`tidyUp`).
        guard let moment = plan.attachment else {
            await tidyUp(incoming: plan.subject)
            return content
        }
        // The refresh fetched at most the widget's thumbnail; pull only what the
        // banner attaches — the thumbnail, or a memo's recording — and only while
        // there's time left for the words to go out anyway.
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
        await tidyUp(incoming: plan.subject)
        return content
    }

    /// Earlier banners this pass can now complete — reworded, given their
    /// picture, withdrawn — since the phone may have been locked when they came.
    /// Bounded, and skipped once out of time: this push's banner goes out regardless.
    private func tidyUp(incoming: BannerSubject?) async {
        guard !Task.isCancelled else { return }
        try? await withDeadline(3) { await BannerUpkeep.run(incoming: incoming) }
    }

    private func momentCandidates() -> [Moment] {
        let floor = SharedStore.shared.snapshot.lastAnnouncedMomentSentAt
        return AnnouncementPolicy.bannerCandidates(MomentIndex.shared.load(), floor: floor)
    }

    private func apply(_ plan: PushBannerPolicy.Plan, to content: UNMutableNotificationContent) {
        if let title = plan.title { content.title = title }
        if let body = plan.body { content.body = body }
        if let thread = plan.thread { content.threadIdentifier = thread }
        if let category = plan.heldCategory { content.userInfo[NotificationCategory.heldBannerKey] = category }
        if let subject = plan.subject { content.userInfo[BannerSubject.key] = subject.stamp }
        if plan.dropsCategory { content.categoryIdentifier = "" }
        if plan.sound { content.sound = .default }
        switch plan.volume {
        case .asSent:
            break
        case .quiet:
            content.sound = nil
            content.interruptionLevel = .passive
        case .silent:
            content.sound = nil
            content.interruptionLevel = .active
        case .active:
            content.interruptionLevel = .active
        case .timeSensitive:
            content.interruptionLevel = .timeSensitive
        }
    }
}
