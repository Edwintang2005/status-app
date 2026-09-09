import Foundation

/// When the two of them began — set by the zone owner, synced to the partner,
/// and the clock behind the hidden count screen. The owner's time zone travels
/// with it so the monthly mark lands on the same wall-clock moment for both,
/// across daylight saving and wherever either phone happens to be.
struct Anniversary: Codable, Hashable, Sendable {
    var startsAt: Date
    var timeZoneID: String

    init(startsAt: Date, timeZoneID: String = TimeZone.current.identifier) {
        // Whole seconds, like every persisted date — see `StatusHistoryEntry.at`.
        self.startsAt = Date(timeIntervalSince1970: startsAt.timeIntervalSince1970.rounded(.down))
        self.timeZoneID = timeZoneID
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    struct Milestone: Hashable {
        let months: Int
        let date: Date

        var title: String {
            if months % 12 == 0 {
                let years = months / 12
                return years == 1 ? String(localized: "1 year") : String(localized: "\(years) years")
            }
            return months == 1 ? String(localized: "1 month") : String(localized: "\(months) months")
        }
    }

    /// Monthly to a year, then yearly; ascending, so the first date past `now`
    /// is the next one.
    func milestones() -> [Milestone] {
        let months = [1, 2, 3, 6, 9, 12] + stride(from: 24, through: 12 * 60, by: 12)
        let calendar = self.calendar
        return months.compactMap { count in
            calendar.date(byAdding: .month, value: count, to: startsAt)
                .map { Milestone(months: count, date: $0) }
        }
    }

    /// From tomorrow: today's milestone is the headline, not what's next.
    func nextMilestone(after now: Date) -> Milestone? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: now)) else { return nil }
        return milestones().first { $0.date >= tomorrow }
    }

    /// The milestone landing today (the owner's day), if any — the whole day
    /// celebrates, not just the minute.
    func milestoneToday(_ now: Date) -> Milestone? {
        milestones().first { calendar.isDate($0.date, inSameDayAs: now) }
    }

    /// Calendar months and days between the two *dates*, which is how people
    /// count these things — "3 months today", not "2 months, 30 days" until the minute.
    func monthsAndDays(at now: Date) -> (months: Int, days: Int) {
        let calendar = self.calendar
        let parts = calendar.dateComponents([.month, .day],
                                            from: calendar.startOfDay(for: startsAt),
                                            to: calendar.startOfDay(for: now))
        return (max(0, parts.month ?? 0), max(0, parts.day ?? 0))
    }

    /// Whole days from today to `date`, both taken as calendar days.
    func daysUntil(_ date: Date, from now: Date) -> Int {
        calendar.dateComponents([.day],
                                from: calendar.startOfDay(for: now),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }
}
