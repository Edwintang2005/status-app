import CloudKit
import Foundation
import UserNotifications
import os

/// Applies `BannerUpkeepPolicy` to this app's delivered banners. A rewrite
/// re-adds the banner under its own identifier, which replaces it in place,
/// `.passive` and silent: it already alerted once, and never gets louder.
enum BannerUpkeep {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "BannerUpkeep")

    /// - Parameter caughtUp: this pass's fetch took the whole delta and read every
    ///   record: only then does "nothing unannounced in the index" mean nothing is coming.
    static func run(incoming: BannerSubject? = nil, caughtUp: Bool) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        #if DEBUG
        noteProbe(listed: delivered.count)
        #endif
        let banners = delivered.compactMap { notification -> BannerUpkeepPolicy.Banner? in
            let info = notification.request.content.userInfo
            var held = info[NotificationCategory.heldBannerKey] != nil
            let subject: BannerSubject
            if let stamped = BannerSubject(userInfo: info) {
                subject = stamped
            } else if notification.request.trigger is UNPushNotificationTrigger,
                      let inferred = BannerUpkeepPolicy.inferredSubject(
                        subscriptionID: CKNotification(fromRemoteNotificationDictionary: info)?.subscriptionID,
                        body: notification.request.content.body) {
                subject = inferred
                held = true
            } else {
                return nil
            }
            return BannerUpkeepPolicy.Banner(id: notification.request.identifier,
                                             subject: subject,
                                             held: held,
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
            caughtUp: caughtUp,
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
            case let .rewordStatus(id, status, generic):
                guard claim({ AnnouncementPolicy.claimStatusBanner(for: status, in: &$0) != nil }) else {
                    if generic {
                        // Maybe our own status coming back.
                        removals.append(id)
                    } else {
                        // Theirs, but these words were already announced: keep it as it reads.
                        await replace(id, from: originals[id], moment: nil, title: nil, body: nil,
                                      stamping: .status, in: center)
                    }
                    continue
                }
                let body = PushBannerPolicy.statusBody(status, reportedAt: store.hiddenPartnerStatusAt,
                                                       sealed: snapshot.partnerStatusSealed)
                await replace(id, from: originals[id], moment: nil, title: name, body: body,
                              stamping: .status, in: center)
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

    /// `nil` title and body keep the banner's own words. `stamping` names what a
    /// banner inferred from CloudKit's words is about, so later passes still see it.
    private static func replace(_ id: String, from original: UNNotificationContent?, moment: Moment?,
                                title: String?, body: String?, stamping subject: BannerSubject? = nil,
                                in center: UNUserNotificationCenter) async {
        // Cleared meanwhile — by the user, or the app coming to the front — stays cleared.
        let current = await center.deliveredNotifications()
        guard let original, let existing = current.first(where: { $0.request.identifier == id }) else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? original.title
        content.body = body ?? original.body
        content.categoryIdentifier = original.categoryIdentifier
        if content.categoryIdentifier.isEmpty, subject == .status {
            content.categoryIdentifier = NotificationCategory.status
        }
        content.threadIdentifier = original.threadIdentifier
        var info = original.userInfo
        if let subject { info[BannerSubject.key] = subject.stamp }
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
            #if DEBUG
            noteProbe(rewrite: "failed: \(error.localizedDescription)")
            #endif
            return
        }
        #if DEBUG
        // Probe: does re-adding a delivered banner's identifier replace it in place?
        let after = await center.deliveredNotifications()
        let same = after.filter { $0.request.identifier == id }
        let inPlace = same.count == 1 && same[0].request.content.body == content.body
        let kind = existing.request.trigger is UNPushNotificationTrigger ? "push" : "local"
        noteProbe(rewrite: "\(inPlace ? "replaced in place" : "NOT in place, \(same.count) with its id") "
                  + "(\(kind)), banners \(current.count) → \(after.count)")
        #else
        _ = existing
        #endif
    }

    #if DEBUG
    private static func noteProbe(listed: Int? = nil, rewrite: String? = nil) {
        let store = SharedStore.shared
        var probe = store.bannerProbe(for: SharedStore.processName) ?? .init(at: Date(), listed: 0)
        probe.at = Date()
        if let listed { probe.listed = listed }
        if let rewrite { probe.rewrite = rewrite }
        store.setBannerProbe(probe, for: SharedStore.processName)
    }
    #endif
}
