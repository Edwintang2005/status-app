import Foundation
import UserNotifications
import os

/// Applies `BannerUpkeepPolicy` to this app's delivered banners. A rewrite
/// re-adds the banner under its own identifier, which replaces it in place,
/// `.passive` and silent: it already alerted once, and never gets louder.
enum BannerUpkeep {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "BannerUpkeep")

    static func run(incoming: BannerSubject? = nil) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let banners = delivered.compactMap { notification -> BannerUpkeepPolicy.Banner? in
            let info = notification.request.content.userInfo
            guard let subject = BannerSubject(userInfo: info) else { return nil }
            return BannerUpkeepPolicy.Banner(id: notification.request.identifier,
                                             subject: subject,
                                             held: info[NotificationCategory.heldBannerKey] != nil,
                                             wantsAttachment: info[BannerSubject.wantsAttachmentKey] != nil,
                                             date: notification.date,
                                             body: notification.request.content.body)
        }
        let store = SharedStore.shared
        guard !banners.isEmpty, let pairing = store.pairing else { return }
        let snapshot = store.snapshot
        let theirs = pairing.role.other
        let heldNames = store.unreadableTally.heldNames
        let index = MomentIndex.shared.loadReadable()
        let state = BannerUpkeepPolicy.State(
            index: index,
            heldMomentIDs: Set(heldNames.compactMap(theirs.momentID(fromRecordName:))),
            hidden: store.hiddenMomentIDs,
            hasAttachment: { moment in
                moment.isVoice ? MomentStore.shared.hasAudio(for: moment.id)
                               : MomentStore.shared.hasThumbnail(for: moment.id)
            },
            statusHeld: heldNames.contains(theirs.statusRecordName),
            partnerStatus: snapshot.theirs,
            nothingUnannounced: index.map {
                AnnouncementPolicy.bannerCandidates($0, floor: snapshot.lastAnnouncedMomentSentAt)
                    .allSatisfy { snapshot.hasAnnounced($0.id) }
            } ?? false,
            wordings: { [Self.words(for: $0), PushBannerPolicy.editedCaptionBody($0)] })
        let actions = BannerUpkeepPolicy.plan(banners, state: state, incoming: incoming)
        guard !actions.isEmpty else { return }

        let originals = Dictionary(delivered.map { ($0.request.identifier, $0.request.content) },
                                   uniquingKeysWith: { first, _ in first })
        let name = snapshot.moderatedPartnerName
        var removals: [String] = []
        for action in actions {
            switch action {
            case .remove(let id):
                removals.append(id)
            case let .reword(id, moment):
                guard claim({ BannerUpkeepPolicy.claimReword(moment, in: &$0) }) else {
                    removals.append(id)
                    continue
                }
                await replace(id, from: originals[id], moment: moment,
                              title: moment.displaySenderName(fallback: name),
                              body: Self.words(for: moment), in: center)
            case let .refresh(id, moment):
                let body = Self.words(for: moment)
                // An edited-caption notice keeps its wording; its picture may still land.
                let keeps = originals[id]?.body == PushBannerPolicy.editedCaptionBody(moment)
                await replace(id, from: originals[id], moment: moment,
                              title: keeps ? nil : moment.displaySenderName(fallback: name),
                              body: keeps ? nil : body, in: center)
            case let .rewordStatus(id, status, superseded):
                guard claim({ AnnouncementPolicy.claimStatusBanner(for: status, in: &$0) != nil }) else {
                    // Maybe our own status coming back: the banner that held theirs stays.
                    removals.append(id)
                    removals += superseded.dropLast()
                    continue
                }
                removals += superseded
                let body = PushBannerPolicy.statusBody(status, reportedAt: store.hiddenPartnerStatusAt,
                                                       sealed: snapshot.partnerStatusSealed)
                await replace(id, from: originals[id], moment: nil, title: name, body: body, in: center)
            }
        }
        if !removals.isEmpty { center.removeDeliveredNotifications(withIdentifiers: removals) }
    }

    /// What a banner about this moment says, as every path words it.
    private static func words(for moment: Moment) -> String {
        moment.displayCaption ?? moment.arrivalSummary
    }

    /// Check-and-claim in one locked write (invariant 1), as every banner's claim is.
    private static func claim(_ decide: (inout Snapshot) -> Bool) -> Bool {
        var claimed = false
        _ = SharedStore.shared.mutate(reloadWidgets: false) { claimed = decide(&$0) }
        return claimed
    }

    /// `nil` title and body keep the banner's own words.
    private static func replace(_ id: String, from original: UNNotificationContent?, moment: Moment?,
                                title: String?, body: String?, in center: UNUserNotificationCenter) async {
        // Cleared meanwhile — by the user, or the app coming to the front — stays cleared.
        guard let original,
              await center.deliveredNotifications().contains(where: { $0.request.identifier == id }) else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? original.title
        content.body = body ?? original.body
        content.categoryIdentifier = original.categoryIdentifier
        content.threadIdentifier = original.threadIdentifier
        var info = original.userInfo
        info[NotificationCategory.heldBannerKey] = nil
        info[NotificationCategory.revisedKey] = true
        if let moment {
            if let attachment = MomentAttachment.make(for: moment, suffix: "upkeep") {
                content.attachments = [attachment]
                info[BannerSubject.wantsAttachmentKey] = nil
            } else {
                // Not here yet: a later pass adds it. Here but refused by iOS (a
                // memo past its size limit): asking again would rewrite it forever.
                let onDisk = moment.isVoice ? MomentStore.shared.hasAudio(for: moment.id)
                                            : MomentStore.shared.hasThumbnail(for: moment.id)
                info[BannerSubject.wantsAttachmentKey] = onDisk ? nil : true
            }
        }
        content.userInfo = info
        content.interruptionLevel = .passive
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            log.error("Couldn't rewrite a banner: \(error.localizedDescription, privacy: .public)")
        }
    }
}
