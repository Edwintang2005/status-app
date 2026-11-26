import Foundation

/// What the countdown widget says: days together — the count screen's own,
/// ticking at the hour you began — and the next milestone, or today's.
struct TogetherCountdown: Equatable, Sendable {
    var days: Int
    /// A milestone landing today, on the owner's calendar.
    var today: String?
    var next: (title: String, daysLeft: Int)?

    init(_ anniversary: Anniversary, at now: Date) {
        days = anniversary.elapsed(at: now).days
        today = anniversary.milestoneToday(now)?.title
        next = anniversary.nextMilestone(after: now).map { ($0.title, anniversary.daysUntil($0.date, from: now)) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.days == rhs.days && lhs.today == rhs.today
            && lhs.next?.title == rhs.next?.title && lhs.next?.daysLeft == rhs.next?.daysLeft
    }

    var daysTogether: String {
        days == 1 ? String(localized: "1 day together") : String(localized: "\(days.formatted()) days together")
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
