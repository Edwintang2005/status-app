import Foundation

/// The opt-in milestone reminders: a local notification on the morning of each
/// coming milestone (`Anniversary.milestones()`), on both phones. Worded so the
/// lock screen doesn't give the count away; opening it leads through the tie
/// to the count, which names the milestone.
/// Pure — `NotificationManager.scheduleMilestoneReminders` hands it to the system.
enum MilestoneReminderPlan {
    static let identifierPrefix = "milestone-"
    /// iOS keeps 64 pending requests per app; the rest of ours are immediate.
    /// A year of monthly marks and the yearly ones after fit well inside.
    static let limit = 12
    static let hour = 9

    struct Reminder: Equatable, Sendable {
        var identifier: String
        var months: Int
        /// Floating wall-clock: 9 am on the milestone's day — the owner's calendar
        /// date, like the count screen's "today" — wherever this phone is.
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
        let owner = anniversary.calendar
        var reminders: [Reminder] = []
        for milestone in anniversary.milestones() {
            let day = owner.dateComponents([.year, .month, .day], from: milestone.date)
            let fireAt = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: 0)
            guard let fires = local.date(from: fireAt), fires > now else { continue }
            reminders.append(Reminder(identifier: "\(identifierPrefix)\(milestone.months)",
                                      months: milestone.months,
                                      fireAt: fireAt))
            if reminders.count == limit { break }
        }
        return reminders
    }
}
