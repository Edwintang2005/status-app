import Foundation

/// The opt-in milestone reminders, on both phones: one per coming milestone, worded
/// so the lock screen doesn't give the count away. Pure — `NotificationManager` schedules them.
enum MilestoneReminderPlan {
    static let identifierPrefix = "milestone-"
    /// iOS keeps 64 pending requests per app; the rest of ours are immediate.
    /// A year of monthly marks and the yearly ones after fit well inside.
    static let limit = 12
    static let hour = 9

    struct Reminder: Equatable, Sendable {
        var identifier: String
        var mark: Anniversary.Milestone.Mark
        /// This phone's wall-clock time (`fireDate`).
        var fireAt: DateComponents
    }

    /// Empty when off, unpaired or no date is set: the scheduler then removes
    /// what was pending.
    static func reminders(for anniversary: Anniversary?,
                          enabled: Bool,
                          paired: Bool,
                          now: Date = Date(),
                          calendar local: Calendar = .current) -> [Reminder] {
        guard enabled, paired, let anniversary else { return [] }
        var reminders: [Reminder] = []
        for milestone in anniversary.milestones() {
            guard let exact = fireDate(milestone, of: anniversary, local: local) else { continue }
            // Up to the whole minute the trigger holds: a moment at 23:02:30 never rings at 23:02.
            let fires = Date(timeIntervalSinceReferenceDate: (exact.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
            guard fires > now else { continue }
            let fireAt = local.dateComponents([.year, .month, .day, .hour, .minute], from: fires)
            reminders.append(Reminder(identifier: "\(identifierPrefix)\(milestone.key)",
                                      mark: milestone.mark,
                                      fireAt: fireAt))
            if reminders.count == limit { break }
        }
        return reminders
    }

    /// 9 am on this phone, but only once the milestone has begun — the owner's day for
    /// a calendar mark, its moment for a round number — and before the owner's day ends;
    /// failing both, the moment it begins.
    static func fireDate(_ milestone: Anniversary.Milestone, of anniversary: Anniversary, local: Calendar) -> Date? {
        let owner = anniversary.calendar
        let day = owner.startOfDay(for: milestone.date)
        guard let end = owner.date(byAdding: .day, value: 1, to: day) else { return nil }
        let start = milestone.isMoment ? milestone.date : day
        let morning = local.date(bySettingHour: hour, minute: 0, second: 0, of: start)
        let nextMorning = morning.flatMap { local.date(byAdding: .day, value: 1, to: $0) }
        return [morning, nextMorning].compactMap { $0 }.first { $0 >= start && $0 < end } ?? start
    }
}
