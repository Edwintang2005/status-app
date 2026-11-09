import Foundation

/// The year-in-review montage, decided apart from drawing it: which pictures and
/// statuses, in what order, for how long. `RecapVideo` renders it on the phone.
struct RecapPlan: Equatable, Sendable {
    enum Period: Equatable, Hashable, Sendable {
        case year(Int)
        /// Diagnostics' test run: any time of year.
        case lastTwelveMonths

        func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
            switch self {
            case .year(let year):
                let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
                let end = calendar.date(byAdding: .year, value: 1, to: start) ?? now
                return DateInterval(start: start, end: end)
            case .lastTwelveMonths:
                let start = calendar.date(byAdding: .year, value: -1, to: now) ?? now
                return DateInterval(start: start, end: now)
            }
        }
    }

    enum Slide: Equatable, Sendable {
        case opening
        case picture(Moment)
        case status(StatusHistoryEntry)
        case closing

        var duration: TimeInterval {
            switch self {
            case .opening, .closing: 3
            case .picture: 1.75
            case .status: 2
            }
        }
    }

    var period: Period
    var interval: DateInterval
    var slides: [Slide]
    /// The period's whole tally, not just what made the cut — the opening card's numbers.
    var momentCount: Int
    var statusCount: Int

    var duration: TimeInterval { slides.reduce(0) { $0 + $1.duration } }

    /// ≈ 90 s at most: 3 + 40 × 1.75 + 8 × 2 + 3.
    static let maxPictures = 40
    static let maxStatuses = 8

    /// `statuses` arrive moderated: only words that may be shown (own, or the
    /// partner's neither reported, sealed nor filtered — invariant 20). `nil`
    /// when there's no picture to build around.
    static func make(_ period: Period, moments: [Moment], statuses: [StatusHistoryEntry],
                     now: Date = Date(), calendar: Calendar = .current) -> RecapPlan? {
        let interval = period.interval(now: now, calendar: calendar)
        let inPeriod = moments.filter { $0.kind.isSupported && interval.contains($0.sentAt) }
        let pictures = inPeriod.filter(\.isPicture).sorted { $0.sentAt < $1.sentAt }
        guard !pictures.isEmpty else { return nil }
        let words = statuses.filter { interval.contains($0.at) }.sorted { $0.at < $1.at }
        let shownWords = words.filter {
            !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.emoji.isEmpty
        }

        let picked: [(Date, Slide)] = evenly(pictures, count: maxPictures).map { ($0.sentAt, .picture($0)) }
            + evenly(shownWords, count: maxStatuses).map { ($0.at, .status($0)) }
        // Stable: a status stamped the same second as a picture follows it.
        let middle = picked.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
        return RecapPlan(period: period, interval: interval,
                         slides: [.opening] + middle + [.closing],
                         momentCount: inPeriod.count, statusCount: words.count)
    }

    /// `count` items spread across the whole run, first and last included.
    static func evenly<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        guard count > 1 else { return Array(items.prefix(count)) }
        let step = Double(items.count - 1) / Double(count - 1)
        return (0..<count).map { items[Int((Double($0) * step).rounded())] }
    }

    /// Home's card: the year's recap from 1 December to 31 January.
    static func yearOnOffer(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else { return nil }
        switch month {
        case 12: return year
        case 1: return year - 1
        default: return nil
        }
    }

    /// Settings' row: this year once December starts, else the last full one.
    static func reviewYear(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 2000
        return parts.month == 12 ? year : year - 1
    }
}
