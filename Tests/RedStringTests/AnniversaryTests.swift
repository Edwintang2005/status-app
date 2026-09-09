import XCTest

/// The anniversary the owner sets: whole-second storage, the owner's calendar,
/// and the milestone run the count screen shows.
final class AnniversaryTests: XCTestCase {
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    /// 5 June 2026, 11:02 pm AEST.
    private var began: Anniversary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 23, minute: 2))!
        return Anniversary(startsAt: date, timeZoneID: sydney.identifier)
    }

    private func sydneyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testStartIsStoredInWholeSeconds() {
        let fractional = Date(timeIntervalSince1970: 1_780_000_000.73)
        let anniversary = Anniversary(startsAt: fractional)
        XCTAssertEqual(anniversary.startsAt.timeIntervalSince1970, 1_780_000_000)
    }

    func testUnknownTimeZoneFallsBackToCurrent() {
        let anniversary = Anniversary(startsAt: Date(), timeZoneID: "Nowhere/Nonsense")
        XCTAssertEqual(anniversary.timeZone, .current)
    }

    func testMilestonesAscendAndKeepTheWallClock() {
        let milestones = began.milestones()
        XCTAssertEqual(milestones.prefix(6).map(\.months), [1, 2, 3, 6, 9, 12])
        XCTAssertEqual(milestones.map(\.date), milestones.map(\.date).sorted())
        // Six months lands on 5 December at 11:02 pm Sydney time — daylight
        // saving has started by then, and the wall clock must not drift.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        let six = milestones.first { $0.months == 6 }!
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: six.date)
        XCTAssertEqual([parts.month, parts.day, parts.hour, parts.minute], [12, 5, 23, 2])
        XCTAssertEqual(six.title, "6 months")
        XCTAssertEqual(milestones.first { $0.months == 12 }?.title, "1 year")
        XCTAssertEqual(milestones.first { $0.months == 24 }?.title, "2 years")
    }

    func testMilestoneDayCelebratesAllDayAndNextSkipsIt() {
        let morningOfTheDay = sydneyDate(2026, 12, 5, 8)
        XCTAssertEqual(began.milestoneToday(morningOfTheDay)?.months, 6)
        XCTAssertEqual(began.nextMilestone(after: morningOfTheDay)?.months, 9,
                       "today's milestone is the headline, not what's next")
        XCTAssertNil(began.milestoneToday(sydneyDate(2026, 12, 6)))
        XCTAssertEqual(began.nextMilestone(after: sydneyDate(2026, 12, 6))?.months, 9)
    }

    func testMonthsAndDaysCountCalendarDates() {
        // The morning of the 3-month mark, hours before 11:02 pm.
        XCTAssertEqual(began.monthsAndDays(at: sydneyDate(2026, 9, 5, 8)).months, 3)
        XCTAssertEqual(began.monthsAndDays(at: sydneyDate(2026, 9, 5, 8)).days, 0)
        XCTAssertEqual(began.monthsAndDays(at: sydneyDate(2026, 7, 9)).days, 4)
        XCTAssertEqual(began.daysUntil(sydneyDate(2026, 12, 5, 23), from: sydneyDate(2026, 12, 1, 1)), 4)
    }

    func testRoundTrip() throws {
        let data = try JSONEncoder.shared.encode(began)
        XCTAssertEqual(try JSONDecoder.shared.decode(Anniversary.self, from: data), began)
    }
}
