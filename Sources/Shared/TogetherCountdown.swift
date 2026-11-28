import Foundation

/// What the countdown widget says: days together in the first year — the count
/// screen's own, ticking at the hour you began — then years and days; and the
/// next milestone, or today's.
struct TogetherCountdown: Equatable, Sendable {
    var days: Int
    /// From the first anniversary, the count is in years (`Anniversary.yearsAndDays`).
    var years: Int
    var daysIntoYear: Int
    /// A milestone landing today, on the owner's calendar.
    var today: String?
    var next: (title: String, short: String, daysLeft: Int)?
    /// The red string: how far from the last milestone (or the start) to the
    /// next, 0...1 — whole on the day itself. `nil` past the last milestone.
    var progress: Double?
    /// The string's left knot: the last milestone, or the day it began ("5 Jun").
    var since: String

    init(_ anniversary: Anniversary, at now: Date) {
        days = anniversary.elapsed(at: now).days
        (years, daysIntoYear) = anniversary.yearsAndDays(at: now)
        let today = anniversary.milestoneToday(now)
        self.today = today?.title
        let next = anniversary.nextMilestone(after: now)
        self.next = next.map { ($0.title, $0.shortTitle, anniversary.daysUntil($0.date, from: now)) }
        let last = anniversary.milestones().last { $0.date <= now && $0 != today }
        since = today?.shortTitle ?? last?.shortTitle
            ?? anniversary.startsAt.formatted(Date.FormatStyle(timeZone: anniversary.timeZone).day().month(.abbreviated))
        if today != nil {
            progress = 1
        } else if let next {
            let from = last?.date ?? anniversary.startsAt
            let span = next.date.timeIntervalSince(from)
            progress = span > 0 ? min(max(now.timeIntervalSince(from) / span, 0), 1) : 0
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.days == rhs.days && lhs.years == rhs.years && lhs.daysIntoYear == rhs.daysIntoYear
            && lhs.today == rhs.today && lhs.since == rhs.since
            && lhs.next?.title == rhs.next?.title && lhs.next?.daysLeft == rhs.next?.daysLeft
            && lhs.progress == rhs.progress
    }

    /// The string's right knot: "6 mo · 9 days", "6 mo · tomorrow", "6 months today".
    var nextShortLine: String? {
        if let today { return String(localized: "\(today) today") }
        guard let next else { return nil }
        switch next.daysLeft {
        case 0: return String(localized: "\(next.short) · later today")
        case 1: return String(localized: "\(next.short) · tomorrow")
        default: return String(localized: "\(next.short) · \(next.daysLeft) days")
        }
    }

    private var isDayOne: Bool { years == 0 && days == 0 }

    private var yearsWord: String {
        years == 1 ? String(localized: "1 year") : String(localized: "\(years) years")
    }

    private var daysWord: String {
        daysIntoYear == 1 ? String(localized: "1 day") : String(localized: "\(daysIntoYear) days")
    }

    /// The home screen's headline and the line under it: "173" / "days" in the
    /// first year, "10" / "years, 364 days" after it, "Day one" on the first.
    var headline: (count: String, unit: String?) {
        if years > 0 {
            let unit = years == 1 ? String(localized: "year") : String(localized: "years")
            return ("\(years)", daysIntoYear == 0 ? unit : String(localized: "\(unit), \(daysWord)"))
        }
        if isDayOne { return (String(localized: "Day one"), nil) }
        return (days.formatted(), days == 1 ? String(localized: "day") : String(localized: "days"))
    }

    /// One line: "173 days", "10 years, 364 days", "11 years", "Day one".
    var countLine: String {
        if years > 0 { return daysIntoYear == 0 ? yearsWord : String(localized: "\(yearsWord), \(daysWord)") }
        if isDayOne { return String(localized: "Day one") }
        return days == 1 ? String(localized: "1 day") : String(localized: "\(days.formatted()) days")
    }

    /// The lock screen's circle: "173", "10y" over "364d", "11y" over "today".
    var compact: (count: String, under: String?) {
        if years > 0 {
            return (String(localized: "\(years)y"),
                    daysIntoYear > 0 ? String(localized: "\(daysIntoYear)d") : today.map { _ in String(localized: "today") })
        }
        if isDayOne { return (String(localized: "Day"), String(localized: "one")) }
        return (days.formatted(), nil)
    }

    var daysTogether: String {
        isDayOne ? String(localized: "Day one together") : String(localized: "\(countLine) together")
    }

    /// "6 months today", "100 days later today", "6 months tomorrow", "6 months in 9 days".
    var nextLine: String? {
        if let today { return String(localized: "\(today) today") }
        guard let next else { return nil }
        switch next.daysLeft {
        case 0: return String(localized: "\(next.title) later today")
        case 1: return String(localized: "\(next.title) tomorrow")
        default: return String(localized: "\(next.title) in \(next.daysLeft) days")
        }
    }

    /// When the widget's numbers next change, ascending: the count ticks at the
    /// hour you began; "today" and "in N days" at the owner's midnight; a round
    /// number at its moment. A timeline of these needs no reload until the last.
    static func changes(for anniversary: Anniversary, after now: Date, count: Int = 8) -> [Date] {
        let calendar = anniversary.calendar
        let days = anniversary.elapsed(at: now).days
        let ticks = (1...count).compactMap { calendar.date(byAdding: .day, value: days + $0, to: anniversary.startsAt) }
        let midnights = (1...count).compactMap {
            calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))
        }
        let moments = anniversary.milestones().lazy.filter { $0.isMoment && $0.date > now }.prefix(1).map(\.date)
        return Array(Set(ticks + midnights + moments).filter { $0 > now }.sorted().prefix(count))
    }
}
