import XCTest

/// The countdown widget's words and when they change.
final class TogetherCountdownTests: XCTestCase {
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    private func sydneyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 5 June 2026, 11:02 pm in Sydney.
    private var began: Anniversary { Anniversary(startsAt: sydneyDate(2026, 6, 5, 23, 2), timeZoneID: sydney.identifier) }

    func testItCountsTheDaysAndNamesWhatsNext() {
        let countdown = TogetherCountdown(began, at: sydneyDate(2026, 11, 26))
        XCTAssertEqual(countdown.days, 173, "the count screen's own number")
        XCTAssertNil(countdown.today)
        XCTAssertEqual(countdown.nextLine, "6 months in 9 days")
    }

    func testAMilestoneDaySaysToday() {
        let countdown = TogetherCountdown(began, at: sydneyDate(2026, 12, 5, 9))
        XCTAssertEqual(countdown.nextLine, "6 months today")
        XCTAssertEqual(TogetherCountdown(began, at: sydneyDate(2026, 12, 4)).nextLine, "6 months tomorrow")
    }

    func testRoundNumbersCountToo() {
        XCTAssertEqual(TogetherCountdown(began, at: sydneyDate(2026, 12, 6)).nextLine, "200 days in 16 days")
    }

    func testTheTimelineChangesAtTheTickAndAtMidnight() {
        let now = sydneyDate(2026, 11, 26, 12)
        let changes = TogetherCountdown.changes(for: began, after: now)
        XCTAssertEqual(changes.first, sydneyDate(2026, 11, 26, 23, 2), "tonight's tick, at the hour you began")
        XCTAssertEqual(changes.dropFirst().first, sydneyDate(2026, 11, 27, 0), "then midnight")
        XCTAssertEqual(changes, changes.sorted())
        XCTAssertTrue(changes.allSatisfy { $0 > now })
        XCTAssertEqual(changes.count, 8)
        // Every entry's numbers differ from the one before: nothing redrawn for nothing.
        for (before, after) in zip([now] + changes, changes) {
            XCTAssertNotEqual(TogetherCountdown(began, at: before), TogetherCountdown(began, at: after), "\(after)")
        }
    }

    /// The count reaches 100 at 11:02 pm, not at midnight: the celebration waits for it.
    func testARoundNumberIsCelebratedFromItsMoment() {
        let morning = TogetherCountdown(began, at: sydneyDate(2026, 9, 13, 9))
        XCTAssertEqual(morning.days, 99)
        XCTAssertEqual(morning.nextLine, "100 days later today")
        let night = TogetherCountdown(began, at: sydneyDate(2026, 9, 13, 23, 30))
        XCTAssertEqual(night.days, 100)
        XCTAssertEqual(night.nextLine, "100 days today")
        XCTAssertTrue(TogetherCountdown.changes(for: began, after: sydneyDate(2026, 9, 13, 9))
            .contains(sydneyDate(2026, 9, 13, 23, 2)), "the widget turns over with it")
    }

    /// The red string runs from the last milestone to the next.
    func testTheStringRunsFromTheLastMilestoneToTheNext() throws {
        // 26 Nov: 100 days was 13 Sep, 6 months is 5 Dec at 11:02 pm.
        let countdown = TogetherCountdown(began, at: sydneyDate(2026, 11, 26))
        XCTAssertEqual(countdown.since, "100 d")
        XCTAssertEqual(countdown.nextShortLine, "6 mo · 9 days")
        let progress = try XCTUnwrap(countdown.progress)
        XCTAssertEqual(progress, 73.5 / 83, accuracy: 0.001, "73½ of the 83 days between them")

        let first = TogetherCountdown(began, at: sydneyDate(2026, 6, 20))
        // In the phone's own words and order: "5 Jun", "Jun 5", "5 juin".
        XCTAssertEqual(first.since, began.startsAt.formatted(Date.FormatStyle(timeZone: sydney).day().month(.abbreviated)),
                       "before any milestone, the day it began")
        XCTAssertEqual(first.nextShortLine, "1 mo · 15 days")
    }

    func testOnTheDayTheStringIsTiedOff() {
        let day = TogetherCountdown(began, at: sydneyDate(2026, 12, 5, 9))
        XCTAssertEqual(day.progress, 1)
        XCTAssertEqual(day.since, "6 mo")
        XCTAssertEqual(day.nextShortLine, "6 months today")
        XCTAssertEqual(TogetherCountdown(began, at: sydneyDate(2026, 12, 6)).progress ?? 1, 0, accuracy: 0.05,
                       "the next morning a new string starts")
    }

    func testShortTitles() {
        let all = began.milestones()
        XCTAssertEqual(all.first { $0.mark == .months(12) }?.shortTitle, "1 yr")
        XCTAssertEqual(all.first { $0.mark == .days(1_000) }?.shortTitle, "\(1_000.formatted()) d")
        XCTAssertEqual(all.first { $0.mark == .hours(10_000) }?.shortTitle, "\(10_000.formatted()) h")
    }

    // MARK: Years and days

    func testTheFirstYearCountsDays() {
        let countdown = TogetherCountdown(began, at: sydneyDate(2026, 11, 26))
        XCTAssertEqual(countdown.years, 0)
        XCTAssertEqual(countdown.headline.count, "173")
        XCTAssertEqual(countdown.headline.unit, "days")
        XCTAssertEqual(countdown.countLine, "173 days")
        XCTAssertNil(countdown.compact.under)
    }

    func testAfterTheFirstAnniversaryItCountsYearsAndDays() {
        let countdown = TogetherCountdown(began, at: sydneyDate(2037, 6, 4))
        XCTAssertEqual(countdown.years, 10)
        XCTAssertEqual(countdown.daysIntoYear, 364)
        XCTAssertEqual(countdown.headline.count, "10")
        XCTAssertEqual(countdown.headline.unit, "years, 364 days")
        XCTAssertEqual(countdown.daysTogether, "10 years, 364 days together")
        XCTAssertEqual(countdown.compact.count, "10y")
        XCTAssertEqual(countdown.compact.under, "364d")
        XCTAssertEqual(countdown.since, "\(4_000.formatted()) d", "the round number since the 10th")
        XCTAssertEqual(countdown.nextShortLine, "11 yr · tomorrow")
    }

    /// From the owner's midnight, hours before 11:02 pm: the count and the string agree.
    func testOnTheAnniversaryItIsWholeYears() {
        let countdown = TogetherCountdown(began, at: sydneyDate(2037, 6, 5, 8))
        XCTAssertEqual(countdown.countLine, "11 years")
        XCTAssertEqual(countdown.headline.unit, "years")
        XCTAssertEqual(countdown.compact.under, "today")
        XCTAssertEqual(countdown.nextShortLine, "11 years today")
        XCTAssertEqual(TogetherCountdown(began, at: sydneyDate(2027, 6, 6)).countLine, "1 year, 1 day")
    }

    /// The years come from the same yearly marks as the milestones.
    func testALeapDayStartTurnsAYearWithItsMilestone() {
        let leap = Anniversary(startsAt: sydneyDate(2024, 2, 29, 20), timeZoneID: sydney.identifier)
        XCTAssertEqual(TogetherCountdown(leap, at: sydneyDate(2025, 2, 28)).countLine, "1 year")
        XCTAssertEqual(TogetherCountdown(leap, at: sydneyDate(2025, 2, 28)).today, "1 year")
        XCTAssertEqual(TogetherCountdown(leap, at: sydneyDate(2025, 3, 1)).countLine, "1 year, 1 day")
        XCTAssertEqual(TogetherCountdown(leap, at: sydneyDate(2028, 2, 28)).countLine, "3 years, 365 days",
                       "the year before a leap anniversary runs a day long")
        XCTAssertEqual(TogetherCountdown(leap, at: sydneyDate(2028, 2, 29)).countLine, "4 years")
    }

    func testTheFirstDayIsDayOne() {
        let today = Anniversary(startsAt: sydneyDate(2026, 11, 26, 9), timeZoneID: sydney.identifier)
        let countdown = TogetherCountdown(today, at: sydneyDate(2026, 11, 26, 18))
        XCTAssertEqual(countdown.headline.count, "Day one")
        XCTAssertNil(countdown.headline.unit)
        XCTAssertEqual(countdown.daysTogether, "Day one together")
        XCTAssertEqual(countdown.compact.count, "Day")
        XCTAssertEqual(TogetherCountdown(today, at: sydneyDate(2026, 11, 27, 10)).countLine, "1 day")
    }

    func testOneDayIsSingular() {
        let yesterday = Anniversary(startsAt: sydneyDate(2026, 11, 25, 9), timeZoneID: sydney.identifier)
        XCTAssertEqual(TogetherCountdown(yesterday, at: sydneyDate(2026, 11, 26, 10)).daysTogether, "1 day together")
    }
}
