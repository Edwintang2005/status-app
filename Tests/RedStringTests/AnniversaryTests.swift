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

    private func sydneyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
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
        XCTAssertEqual(milestones.compactMap(\.months).prefix(6), [1, 2, 3, 6, 9, 12])
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
        XCTAssertEqual(began.nextMilestone(after: morningOfTheDay)?.mark, .days(200),
                       "today's milestone is the headline, not what's next")
        XCTAssertNil(began.milestoneToday(sydneyDate(2026, 12, 6)))
        XCTAssertEqual(began.nextMilestone(after: sydneyDate(2026, 12, 6))?.mark, .days(200), "22 December, before 9 months")
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

    /// US clocks spring forward on 8 March 2026: the 47 hours from noon on
    /// the 7th to noon on the 9th are still two whole days on the wall.
    func testElapsedCountsCalendarDaysAcrossDaylightSaving() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12, minute: 30)))
        let anniversary = Anniversary(startsAt: start, timeZoneID: zone.identifier)
        XCTAssertEqual(now.timeIntervalSince(start), 47.5 * 3600, "the fixture really spans the change")
        let elapsed = anniversary.elapsed(at: now)
        XCTAssertEqual(elapsed.days, 2)
        XCTAssertEqual(elapsed.seconds, 30 * 60)
        XCTAssertEqual(anniversary.elapsed(at: start.addingTimeInterval(-60)).days, 0, "before it began")
    }

    func testRoundNumbersSitBetweenTheCalendarMarks() {
        let all = began.milestones()
        XCTAssertEqual(all.map(\.date), all.map(\.date).sorted(), "in date order")
        XCTAssertEqual(all.firstIndex { $0.mark == .days(100) }, all.firstIndex { $0.mark == .months(3) }.map { $0 + 1 },
                       "100 days (13 September) comes after 3 months (5 September)")
        let thousand = all.first { $0.mark == .days(1_000) }!
        XCTAssertEqual(thousand.title, "1,000 days")
        XCTAssertEqual(began.daysUntil(thousand.date, from: began.startsAt), 1_000)
        XCTAssertEqual(all.first { $0.mark == .hours(10_000) }?.title, "10,000 hours")
        XCTAssertEqual(began.nextMilestone(after: sydneyDate(2026, 9, 6))?.mark, .days(100))
    }

    func testARoundNumberWaitsForItsMoment() {
        let morning = sydneyDate(2026, 9, 13, 9)
        XCTAssertNil(began.milestoneToday(morning), "99 days until 11:02 pm")
        XCTAssertEqual(began.nextMilestone(after: morning)?.mark, .days(100), "still to come today")
        XCTAssertEqual(began.milestoneToday(sydneyDate(2026, 9, 13, 23, 30))?.mark, .days(100))
    }

    /// The round numbers are chosen to sit weeks from any calendar mark: one celebration a day.
    func testNoDayCarriesTwoMilestones() {
        let all = began.milestones()
        let days = all.map { began.calendar.startOfDay(for: $0.date) }
        XCTAssertEqual(Set(days).count, days.count, "one celebration a day")
    }
}
