import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// How loudly each kind of partner notification may arrive on this phone. Per
/// device; the notification service and the app's own posts both apply it. A
/// push can be made quieter, never dropped (no filtering entitlement), so the
/// quietest level still files it in Notification Centre.
struct NotificationPreferences: Codable, Equatable, Sendable {
    enum Level: String, Codable, CaseIterable, Sendable, Comparable {
        /// Straight to Notification Centre: `.passive`, no sound.
        case list
        /// A banner with no sound, never breaking through Focus.
        case silent
        /// As sent: a banner and a sound (a fresh heart may break through Focus).
        case sound

        static func < (lhs: Level, rhs: Level) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    var statuses: Level = .sound
    var hearts: Level = .sound
    var pictures: Level = .sound
    var voiceMemos: Level = .sound

    init() {}

    /// Field by field: a value another build wrote that this one can't read
    /// costs that kind only, which falls back to sound.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func level(_ key: CodingKeys) -> Level { (try? container.decodeIfPresent(Level.self, forKey: key)) ?? .sound }
        statuses = level(.statuses)
        hearts = level(.hearts)
        pictures = level(.pictures)
        voiceMemos = level(.voiceMemos)
    }

    func level(forMoment kind: Moment.Kind) -> Level {
        if case .voice = kind { return voiceMemos }
        return pictures
    }

    /// The level for one push. A moment push takes the loudest of the kinds the
    /// pass read — a photo-and-memo burst rings if either would — and, with
    /// nothing read (expiry, a locked phone), the louder of the two.
    func level(for push: PushBannerPolicy.Push, momentKinds: [Moment.Kind] = []) -> Level? {
        switch push {
        case .status: return statuses
        case .nudge: return hearts
        case .moment:
            let levels = momentKinds.isEmpty ? [pictures, voiceMemos] : momentKinds.map(level(forMoment:))
            return levels.max()
        case .other: return nil
        }
    }
}

extension PushBannerPolicy.Plan {
    /// Never louder than `level` allows; a plan already quieter stays as it is.
    func limited(to level: NotificationPreferences.Level?) -> Self {
        var plan = self
        switch level {
        case .sound?, nil:
            return plan
        case .silent?:
            plan.sound = false
            if plan.volume != .quiet { plan.volume = .silent }
        case .list?:
            plan.sound = false
            plan.volume = .quiet
        }
        return plan
    }
}

#if canImport(UserNotifications)
extension UNMutableNotificationContent {
    /// The content-level twin of `Plan.limited`: for the app's own posts, and
    /// for the service's content before its plan is known (the expiry fallback).
    func limit(to level: NotificationPreferences.Level?) {
        switch level {
        case .sound?, nil:
            return
        case .silent?:
            sound = nil
            if interruptionLevel == .timeSensitive || interruptionLevel == .critical { interruptionLevel = .active }
        case .list?:
            sound = nil
            interruptionLevel = .passive
            // The open app lists it rather than showing a banner (`willPresent`).
            userInfo[NotificationCategory.listOnlyKey] = true
        }
    }
}
#endif
