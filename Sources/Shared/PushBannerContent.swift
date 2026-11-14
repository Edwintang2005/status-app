import Foundation
import UserNotifications

extension PushBannerPolicy {
    /// The notification service's exits that never reach `decide`: the push
    /// isn't CloudKit's, nobody is linked, the store can't be read yet (before
    /// first unlock), or the refresh failed.
    enum Bypass: Equatable, Sendable {
        case notCloudKit
        /// Old subscriptions still registered after an unlink: quiet, neutral, action-less.
        case unpaired
        /// Nothing here can be read: CloudKit's words, held for whatever reads first to reword.
        case unreadable
        /// The refresh threw: CloudKit's words, held likewise.
        case failed(String)

        /// Before the refresh; `nil` is "go ahead".
        init?(isCloudKitPush: Bool, pairing: SharedStore.PairingState) {
            guard isCloudKitPush else { self = .notCloudKit; return }
            switch pairing {
            case .paired: return nil
            case .unpaired: self = .unpaired
            case .unreadable: self = .unreadable
            }
        }

        /// A refresh that threw.
        init(after error: Error) {
            switch error {
            case SyncError.storeUnreadable: self = .unreadable
            case SyncError.notPaired: self = .unpaired
            default: self = .failed(error.localizedDescription)
            }
        }

        /// Unpaired, there's nothing for the widget to fetch; otherwise this pass
        /// didn't finish, so it should.
        var widgetNeedsFetch: Bool { self != .unpaired }

        /// Applies it to the banner; returns what Diagnostics records of the pass.
        func apply(to content: UNMutableNotificationContent,
                   push: Push) -> (outcome: SharedStore.BannerPass.Outcome, detail: String) {
            switch self {
            case .notCloudKit:
                return (.unworded, "not a CloudKit push")
            case .unpaired:
                PushBannerPolicy.unpaired.apply(to: content)
                return (.worded, "unpaired")
            case .unreadable:
                push.markUnworded(content)
                return (.unworded, "store unreadable")
            case .failed(let reason):
                push.markUnworded(content)
                return (.failed, reason)
            }
        }
    }
}

extension PushBannerPolicy.Push {
    /// Still CloudKit's words: tagged as a held banner, so a later refresh rewords it.
    func markUnworded(_ content: UNMutableNotificationContent?) {
        guard let content, let subject = unwordedSubject else { return }
        content.userInfo[BannerSubject.key] = subject.stamp
        content.userInfo[NotificationCategory.heldBannerKey] = category
    }
}

extension PushBannerPolicy.Plan {
    /// Words, thread, stamps and volume onto the push's own content.
    func apply(to content: UNMutableNotificationContent) {
        if let title { content.title = title }
        if let body { content.body = body }
        if let thread { content.threadIdentifier = thread }
        if let heldCategory { content.userInfo[NotificationCategory.heldBannerKey] = heldCategory }
        if let subject { content.userInfo[BannerSubject.key] = subject.stamp }
        if dropsCategory { content.categoryIdentifier = "" }
        if sound { content.sound = .default }
        switch volume {
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
