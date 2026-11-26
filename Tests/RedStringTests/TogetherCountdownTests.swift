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
        // In the phone's own order: "5 Jun" here, "Jun 5" on CI's US English.
        XCTAssertTrue(first.since.contains("Jun") && first.since.contains("5"),
                      "before any milestone, the day it began: \(first.since)")
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
        XCTAssertEqual(all.first { $0.mark == .days(1_000) }?.shortTitle, "1,000 d")
        XCTAssertEqual(all.first { $0.mark == .hours(10_000) }?.shortTitle, "10,000 h")
    }

    func testOneDayIsSingular() {
        let yesterday = Anniversary(startsAt: sydneyDate(2026, 11, 25, 9), timeZoneID: sydney.identifier)
        XCTAssertEqual(TogetherCountdown(yesterday, at: sydneyDate(2026, 11, 26, 10)).daysTogether, "1 day together")
    }
}
