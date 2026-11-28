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
        self.startsAt = startsAt.wholeSeconds
        self.timeZoneID = timeZoneID
    }

    private enum CodingKeys: String, CodingKey {
        case startsAt, timeZoneID
    }

    /// Hand-written (invariant 5): new fields must fall back, not fail the snapshot.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startsAt = try container.decode(Date.self, forKey: .startsAt)
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier
    }

    /// The earliest date accepted from the zone: older than any couple, and
    /// still inside what ISO-8601 reads back (a negative year isn't).
    static let earliest = Date(timeIntervalSince1970: -2_208_988_800)  // 1900-01-01

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    struct Milestone: Hashable, Sendable {
        /// A calendar mark (months, then years) or a round number of days or hours.
        enum Mark: Hashable, Sendable {
            case months(Int)
            case days(Int)
            case hours(Int)
        }

        let mark: Mark
        let date: Date

        /// The month count for a calendar mark; `nil` for a round number.
        var months: Int? {
            if case .months(let count) = mark { count } else { nil }
        }

        /// A round number is reached at its moment, when the count ticks over —
        /// a calendar mark is a date, "3 months today" all day.
        var isMoment: Bool { months == nil }

        /// This milestone of this date: a changed date is a new one.
        func dayKey(of anniversary: Anniversary) -> String {
            "\(Int(anniversary.startsAt.timeIntervalSince1970)):\(key)"
        }

        /// Stable per milestone, for its reminder (`MilestoneReminderPlan`).
        var key: String {
            switch mark {
            case .months(let count): "\(count)"
            case .days(let count): "d\(count)"
            case .hours(let count): "h\(count)"
            }
        }

        /// For a widget's tight corners: "6 mo", "1 yr", "100 d", "10,000 h".
        var shortTitle: String {
            switch mark {
            case .months(let months) where months % 12 == 0: String(localized: "\(months / 12) yr")
            case .months(let months): String(localized: "\(months) mo")
            case .days(let days): String(localized: "\(days.formatted()) d")
            case .hours(let hours): String(localized: "\(hours.formatted()) h")
            }
        }

        var title: String {
            switch mark {
            case .months(let months) where months % 12 == 0:
                let years = months / 12
                return years == 1 ? String(localized: "1 year") : String(localized: "\(years) years")
            case .months(let months):
                return months == 1 ? String(localized: "1 month") : String(localized: "\(months) months")
            case .days(let days):
                return String(localized: "\(days.formatted()) days")
            case .hours(let hours):
                return String(localized: "\(hours.formatted()) hours")
            }
        }
    }

    /// Round numbers worth a moment of their own, between the calendar marks.
    static let roundDays = [100, 200, 300, 500, 1_000, 1_500, 2_000, 2_500, 3_000, 4_000,
                            5_000, 6_000, 7_000, 8_000, 9_000, 10_000]
    static let roundHours = [10_000, 100_000]

    /// Monthly to a year, then yearly, with the round numbers between; in date
    /// order. None share a day (the nearest pair is weeks apart; a test keeps it so).
    func milestones() -> [Milestone] {
        let months = [1, 2, 3, 6, 9, 12] + stride(from: 24, through: 12 * 60, by: 12)
        let calendar = self.calendar
        let marks = months.compactMap { count in
            calendar.date(byAdding: .month, value: count, to: startsAt).map { Milestone(mark: .months(count), date: $0) }
        }
        let round = Self.roundDays.compactMap { count in
            calendar.date(byAdding: .day, value: count, to: startsAt).map { Milestone(mark: .days(count), date: $0) }
        } + Self.roundHours.map { Milestone(mark: .hours($0), date: startsAt.addingTimeInterval(Double($0) * 3_600)) }
        return (marks + round).sorted { $0.date < $1.date }
    }

    /// Today's milestone is the headline, not what's next; a round number later
    /// today is still to come.
    func nextMilestone(after now: Date) -> Milestone? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: now)) else { return nil }
        return milestones().first { $0.date >= tomorrow || ($0.isMoment && $0.date > now) }
    }

    /// The milestone being celebrated (the owner's day), if any: a calendar
    /// mark all day, a round number from its moment — so the count under it agrees.
    func milestoneToday(_ now: Date) -> Milestone? {
        milestones().first { calendar.isDate($0.date, inSameDayAs: now) && (!$0.isMoment || $0.date <= now) }
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

    /// Full days and the seconds past the last whole day since `startsAt`, on
    /// the owner's calendar: a daylight-saving day of 23 or 25 hours still
    /// counts as one day, which dividing by 86,400 wouldn't.
    func elapsed(at now: Date) -> (days: Int, seconds: Int) {
        guard now > startsAt else { return (0, 0) }
        let parts = calendar.dateComponents([.day, .hour, .minute, .second], from: startsAt, to: now)
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        return (max(0, parts.day ?? 0), max(0, seconds))
    }

    /// When `milestoneToday` can next change: a round number arriving later
    /// today, or else the owner's next midnight.
    func milestoneTodayChanges(after now: Date) -> Date? {
        let calendar = self.calendar
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        return milestones().first { $0.isMoment && $0.date > now && $0.date < midnight }?.date ?? midnight
    }

    /// Whole years by the yearly marks — `milestones()`'s own, so a 29 February
    /// start turns a year on 28 February — and calendar days since the last.
    /// Both turn over at the owner's midnight, with "today" on the widget.
    func yearsAndDays(at now: Date) -> (years: Int, days: Int) {
        let calendar = self.calendar
        let today = calendar.startOfDay(for: now)
        var years = 0
        var lastMark = calendar.startOfDay(for: startsAt)
        while let mark = calendar.date(byAdding: .month, value: 12 * (years + 1), to: startsAt).map(calendar.startOfDay),
              mark <= today {
            years += 1
            lastMark = mark
        }
        return (years, max(0, calendar.dateComponents([.day], from: lastMark, to: today).day ?? 0))
    }

    /// Whole days from today to `date`, both taken as calendar days.
    func daysUntil(_ date: Date, from now: Date) -> Int {
        calendar.dateComponents([.day],
                                from: calendar.startOfDay(for: now),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }
}
