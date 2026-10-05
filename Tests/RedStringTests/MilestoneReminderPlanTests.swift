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
        XCTAssertEqual(first?.months, 1)
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
        XCTAssertEqual(plan.first?.months, 6, "1, 2 and 3 months have passed")
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
        XCTAssertEqual(plan(sydneyDate(2026, 9, 5, 8)).first?.months, 3)
        XCTAssertEqual(plan(sydneyDate(2026, 9, 5, 10)).first?.months, 6, "9 am has gone")
    }

    func testAChangedDateChangesThePlan() {
        let now = sydneyDate(2026, 6, 10)
        let moved = Anniversary(startsAt: began.startsAt.addingTimeInterval(86_400), timeZoneID: sydney.identifier)
        XCTAssertNotEqual(MilestoneReminderPlan.reminders(for: began, enabled: true, paired: true, now: now),
                          MilestoneReminderPlan.reminders(for: moved, enabled: true, paired: true, now: now))
    }
}
