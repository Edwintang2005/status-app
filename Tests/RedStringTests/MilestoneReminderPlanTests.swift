import XCTest

/// The opt-in milestone reminders: what gets scheduled, when, and that the
/// plan empties (so the scheduler removes them) whenever it should.
final class MilestoneReminderPlanTests: XCTestCase {
    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let london = TimeZone(identifier: "Europe/London")!

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// 5 June 2026, 11:02 pm in Sydney.
    private var began: Anniversary {
        let date = calendar(sydney).date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 23, minute: 2))!
        return Anniversary(startsAt: date, timeZoneID: sydney.identifier)
    }

    private func sydneyDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar(sydney).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testOffUnpairedOrUnsetPlansNothing() {
        let now = sydneyDate(2026, 6, 10)
        XCTAssertEqual(MilestoneReminderPlan.reminders(for: began, enabled: false, paired: true, now: now), [])
        XCTAssertEqual(MilestoneReminderPlan.reminders(for: began, enabled: true, paired: false, now: now), [])
        XCTAssertEqual(MilestoneReminderPlan.reminders(for: nil, enabled: true, paired: true, now: now), [])
    }

    func testMorningOfTheOwnersDateWhereverThePhoneIs() {
        let now = sydneyDate(2026, 6, 10)
        let plan = MilestoneReminderPlan.reminders(for: began, enabled: true, paired: true, now: now,
                                                   calendar: calendar(london))
        let first = try? XCTUnwrap(plan.first)
        XCTAssertEqual(first?.mark, .months(1))
        XCTAssertEqual(first?.identifier, "milestone-1")
        // The mark lands at 11:02 pm on 5 July in Sydney: the reminder is that
        // date's morning, as a floating wall-clock time.
        XCTAssertEqual(first?.fireAt, DateComponents(year: 2026, month: 7, day: 5, hour: 9, minute: 0))
        XCTAssertNil(first?.fireAt.timeZone)
    }

    func testPassedMilestonesAreSkippedAndThePlanIsCapped() {
        let now = sydneyDate(2026, 9, 6)
        let plan = MilestoneReminderPlan.reminders(for: began, enabled: true, paired: true, now: now,
                                                   calendar: calendar(sydney))
        XCTAssertEqual(plan.first?.mark, .days(100), "1, 2 and 3 months have passed; 100 days comes next")
        XCTAssertEqual(plan.count, MilestoneReminderPlan.limit)
        XCTAssertLessThan(MilestoneReminderPlan.limit, 64, "iOS keeps 64 pending per app")
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count)
        XCTAssertTrue(plan.allSatisfy { $0.identifier.hasPrefix(MilestoneReminderPlan.identifierPrefix) })
    }

    func testTodaysReminderIsKeptUntilItsHour() {
        let plan = { (now: Date) in
            MilestoneReminderPlan.reminders(for: self.began, enabled: true, paired: true, now: now,
                                            calendar: self.calendar(self.sydney))
        }
        XCTAssertEqual(plan(sydneyDate(2026, 9, 5, 8)).first?.mark, .months(3))
        XCTAssertEqual(plan(sydneyDate(2026, 9, 5, 10)).first?.mark, .days(100), "9 am has gone")
    }

    func testAChangedDateChangesThePlan() {
        let now = sydneyDate(2026, 6, 10)
        let moved = Anniversary(startsAt: began.startsAt.addingTimeInterval(86_400), timeZoneID: sydney.identifier)
        XCTAssertNotEqual(MilestoneReminderPlan.reminders(for: began, enabled: true, paired: true, now: now),
                          MilestoneReminderPlan.reminders(for: moved, enabled: true, paired: true, now: now))
    }

    func testRoundNumbersAreRemindedTooUnderTheirOwnNames() {
        let plan = MilestoneReminderPlan.reminders(for: began, enabled: true, paired: true,
                                                   now: sydneyDate(2026, 9, 6), calendar: calendar(sydney))
        XCTAssertTrue(plan.contains { $0.identifier == "milestone-d100" })
        XCTAssertTrue(plan.contains { $0.identifier == "milestone-6" })
        // 100 days from 5 June, 11:02 pm in Sydney: 13 September, when the count reaches it.
        XCTAssertEqual(plan.first { $0.mark == .days(100) }?.fireAt,
                       DateComponents(year: 2026, month: 9, day: 13, hour: 23, minute: 2))
        // Reached before 9 am, a round number is reminded at 9, like the marks.
        let early = Anniversary(startsAt: calendar(sydney).date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 6))!,
                                timeZoneID: sydney.identifier)
        let earlyPlan = MilestoneReminderPlan.reminders(for: early, enabled: true, paired: true,
                                                        now: sydneyDate(2026, 9, 6), calendar: calendar(sydney))
        XCTAssertEqual(earlyPlan.first { $0.mark == .days(100) }?.fireAt,
                       DateComponents(year: 2026, month: 9, day: 13, hour: 9, minute: 0))
    }

    /// Owner in London, the phone in Sydney, nine hours ahead: 100 days reached at
    /// 11:02 pm London is 8:02 am Sydney the next day — never reminded before that.
    func testAPhoneEastOfTheOwnerHearsOnlyOnceItsBegun() {
        let londonCalendar = calendar(london)
        let began = Anniversary(startsAt: londonCalendar.date(from: DateComponents(year: 2026, month: 6, day: 5,
                                                                                    hour: 23, minute: 2, second: 30))!,
                                timeZoneID: london.identifier)
        let hundred = began.milestones().first { $0.mark == .days(100) }!
        let phone = calendar(sydney)
        let reminder = MilestoneReminderPlan.reminders(for: began, enabled: true, paired: true,
                                                       now: began.startsAt, calendar: phone)
            .first { $0.mark == .days(100) }!
        let fires = phone.date(from: reminder.fireAt)!
        XCTAssertGreaterThanOrEqual(fires, hundred.date, "the count shows 100 by then, to the second")
        XCTAssertEqual(began.milestoneToday(fires)?.mark, .days(100), "and the count screen names it")
    }

    /// Every milestone, on phones either side of the owner: begun by the time it fires.
    func testNoReminderComesBeforeItsMilestone() {
        for zone in [sydney, london, TimeZone(identifier: "America/Los_Angeles")!, TimeZone(identifier: "Asia/Tokyo")!] {
            for milestone in began.milestones().prefix(20) {
                let fires = MilestoneReminderPlan.fireDate(milestone, of: began, local: calendar(zone))!
                XCTAssertEqual(began.milestoneToday(fires)?.key, milestone.key, "\(milestone.key) on \(zone.identifier)")
            }
        }
    }
}
