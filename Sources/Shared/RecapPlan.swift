import CoreGraphics
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
        /// A collage of 2–4, in date order (one only when the period has just one).
        case pictures([Moment])
        case status(StatusHistoryEntry)
        case closing

        var duration: TimeInterval {
            switch self {
            case .opening, .closing: 3
            case .pictures: 2.5
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

    /// ≈ 90 s at most: 3 + ~27 collages × 2.5 + 8 × 2 + 3.
    static let maxPictures = 80
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

        let picked: [(Date, Slide)] = collages(evenly(pictures, count: maxPictures)).map { ($0[0].sentAt, .pictures($0)) }
            + evenly(shownWords, count: maxStatuses).map { ($0.at, .status($0)) }
        // Stable: a status stamped the same second as a picture follows it.
        let middle = picked.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
        return RecapPlan(period: period, interval: interval,
                         slides: [.opening] + middle + [.closing],
                         momentCount: inPeriod.count, statusCount: words.count)
    }

    /// Whether the period reaches past this phone's index, so only iCloud has
    /// all of it: the index keeps the newest `limit` moments and the zone keeps
    /// every one. Statuses never need it — every phone's log mirrors the
    /// cloud log's pruning.
    static func needsZone(index: [Moment], interval: DateInterval,
                          limit: Int = AppConfig.momentHistoryLimit) -> Bool {
        guard index.count >= limit, let oldest = index.map(\.sentAt).min() else { return false }
        return oldest > interval.start
    }

    /// Consecutive runs of 3, 4, 2, … — never a lone picture left over, nor more than 4.
    static func collages<T>(_ items: [T]) -> [[T]] {
        var groups: [[T]] = []
        var rest = items[...]
        let pattern = [3, 4, 2]
        while !rest.isEmpty {
            guard rest.count > 4 else {
                groups.append(Array(rest))
                break
            }
            var size = pattern[groups.count % pattern.count]
            if rest.count - size == 1 { size = size == 4 ? 3 : size + 1 }
            groups.append(Array(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return groups
    }

    /// Where a collage's pictures sit on a portrait canvas, each cell leaving
    /// `label` below it for its words: a staggered pair, one big over two, or a
    /// 2×2 grid — every cell between square and 3:4, so phone photos lose little.
    static func cells(for count: Int, in canvas: CGSize, label: CGFloat = 56) -> [CGRect] {
        let side: CGFloat = 60, top: CGFloat = 200, gap: CGFloat = 36
        let width = canvas.width - side * 2
        let height = canvas.height - top - 320
        let half = (width - gap) / 2
        func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: side + x, y: top + y, width: w, height: h - label)
        }
        switch count {
        case ...1:
            return [cell(0, 0, width, height)]
        case 2:
            let w = width * 0.6, h = (height - gap) / 2
            return [cell(0, 0, w, h), cell(width - w, h + gap, w, h)]
        case 3:
            let big = height * 0.54, w = min(width, big - label)
            let small = height - big - gap
            return [cell((width - w) / 2, 0, w, big),
                    cell(0, big + gap, half, small), cell(half + gap, big + gap, half, small)]
        default:
            let h = (height - gap) / 2
            return [cell(0, 0, half, h), cell(half + gap, 0, half, h),
                    cell(0, h + gap, half, h), cell(half + gap, h + gap, half, h)]
        }
    }

    /// `count` items spread across the whole run, first and last included.
    static func evenly<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        guard count > 1 else { return Array(items.prefix(count)) }
        let step = Double(items.count - 1) / Double(count - 1)
        return (0..<count).map { items[Int((Double($0) * step).rounded())] }
    }

    /// Each year's recap unwraps at midday on Christmas Day, wall-clock
    /// wherever the phone is: a gift, so nothing shows it before then.
    static func unwrapping(_ year: Int) -> DateComponents {
        DateComponents(year: year, month: 12, day: 25, hour: 12, minute: 0)
    }

    static func hasUnwrapped(_ year: Int, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let at = calendar.date(from: unwrapping(year)) else { return false }
        return now >= at
    }

    struct Reminder: Equatable, Sendable {
        var year: Int
        var identifier: String
        /// `unwrapping(year)`, floating.
        var fireAt: DateComponents
    }

    static let reminderPrefix = "recap-"
    /// userInfo key naming the reminder's year, for the tap's route.
    static let reminderYearKey = "recap-year"

    /// The Christmas note that this year's recap is ready: while paired, once
    /// the year has a picture, until it fires — never for a year already
    /// opened or waved away. `nil`: the scheduler removes a pending one.
    static func reminder(paired: Bool, hasPictures: (Int) -> Bool, dismissed: Int?,
                         now: Date = Date(), calendar: Calendar = .current) -> Reminder? {
        guard paired, let year = calendar.dateComponents([.year], from: now).year,
              dismissed != year, hasPictures(year),
              !hasUnwrapped(year, now: now, calendar: calendar) else { return nil }
        return Reminder(year: year, identifier: "\(reminderPrefix)\(year)", fireAt: unwrapping(year))
    }

    /// Home's card: the year's recap from Christmas midday to 31 January.
    static func yearOnOffer(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else { return nil }
        switch month {
        case 12: return hasUnwrapped(year, now: now, calendar: calendar) ? year : nil
        case 1: return year - 1
        default: return nil
        }
    }

    /// Settings' row: this year once it's unwrapped, else the last full one.
    static func reviewYear(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let year = calendar.dateComponents([.year], from: now).year ?? 2000
        return hasUnwrapped(year, now: now, calendar: calendar) ? year : year - 1
    }
}
