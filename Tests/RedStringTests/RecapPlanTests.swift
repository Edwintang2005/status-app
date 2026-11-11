import XCTest

/// The year in review (`RecapPlan`): what goes in, in what order, and when it's offered.
final class RecapPlanTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func entry(_ message: String, at date: Date, fromMe: Bool = false) -> StatusHistoryEntry {
        StatusHistoryEntry(emoji: "🙂", message: message, isCelebration: false, at: date, fromMe: fromMe)
    }

    private func plan(_ period: RecapPlan.Period, moments: [Moment], statuses: [StatusHistoryEntry] = [],
                      now: Date? = nil) -> RecapPlan? {
        RecapPlan.make(period, moments: moments, statuses: statuses,
                       now: now ?? day(2026, 12, 5), calendar: calendar)
    }

    func testOnlyTheYearsPicturesGoIn() throws {
        let moments = [Fixtures.moment("old", at: day(2025, 12, 31)),
                       Fixtures.moment("memo", kind: .voice, at: day(2026, 3, 1)),
                       Fixtures.moment("future", kind: .unsupported("sticker"), at: day(2026, 4, 1)),
                       Fixtures.moment("doodle", kind: .drawing, at: day(2026, 5, 1)),
                       Fixtures.moment("photo", at: day(2026, 2, 1))]
        let recap = try XCTUnwrap(plan(.year(2026), moments: moments))
        XCTAssertEqual(recap.slides.first, .opening)
        XCTAssertEqual(recap.slides.last, .closing)
        let ids = pictures(in: recap).map(\.id)
        XCTAssertEqual(ids, ["photo", "doodle"], "date order; no memo, newer kind or other year")
        XCTAssertEqual(recap.momentCount, 3, "the tally counts the memo, not a kind this build can't show")
    }

    func testNoPicturesNoRecap() {
        XCTAssertNil(plan(.year(2026), moments: [Fixtures.moment("memo", kind: .voice, at: day(2026, 3, 1))],
                          statuses: [entry("hi", at: day(2026, 3, 2))]))
    }

    func testStatusesInterleaveByDate() throws {
        let january = (1...3).map { Fixtures.moment("j\($0)", at: day(2026, 1, $0)) }
        let june = (1...3).map { Fixtures.moment("n\($0)", at: day(2026, 6, $0)) }
        let statuses = [entry("spring", at: day(2026, 3, 1)), entry("last year", at: day(2025, 6, 1)),
                        StatusHistoryEntry(emoji: "", message: "  ", isCelebration: false,
                                           at: day(2026, 4, 1), fromMe: true)]
        let recap = try XCTUnwrap(plan(.year(2026), moments: june + january, statuses: statuses))
        XCTAssertEqual(recap.slides, [.opening, .pictures(january), .status(statuses[0]), .pictures(june), .closing])
        XCTAssertEqual(recap.statusCount, 2, "a blank status counts, but isn't drawn")
    }

    /// A busy year stays near 90 seconds, spread across the whole year, two to four to a slide.
    func testABusyYearIsCappedEvenly() throws {
        let moments = (0..<300).map { Fixtures.moment("m\($0)", at: day(2026, 1, 1).addingTimeInterval(Double($0) * 86_400)) }
        let statuses = (0..<100).map { entry("s\($0)", at: day(2026, 1, 2).addingTimeInterval(Double($0) * 3 * 86_400)) }
        let recap = try XCTUnwrap(plan(.year(2026), moments: moments, statuses: statuses))
        let shown = pictures(in: recap)
        XCTAssertEqual(shown.count, RecapPlan.maxPictures)
        XCTAssertEqual(shown.first?.id, "m0")
        XCTAssertEqual(shown.last?.id, "m299")
        XCTAssertEqual(shown.map(\.sentAt), shown.map(\.sentAt).sorted())
        for case .pictures(let group) in recap.slides { XCTAssertTrue((2...4).contains(group.count)) }
        XCTAssertEqual(recap.slides.filter { if case .status = $0 { true } else { false } }.count, RecapPlan.maxStatuses)
        XCTAssertLessThanOrEqual(recap.duration, 95)
        XCTAssertEqual(recap.momentCount, 300)
    }

    func testCollagesNeverLeaveOneAlone() {
        XCTAssertEqual(RecapPlan.collages([1]), [[1]], "a period with one picture shows it")
        for count in 2...40 {
            let groups = RecapPlan.collages(Array(0..<count))
            XCTAssertEqual(groups.flatMap { $0 }, Array(0..<count))
            XCTAssertTrue(groups.allSatisfy { (2...4).contains($0.count) }, "\(count): \(groups.map(\.count))")
        }
    }

    func testCollageCellsStayApartAndOnTheCanvas() {
        let canvas = CGSize(width: 1080, height: 1920)
        for count in 1...4 {
            let cells = RecapPlan.cells(for: count, in: canvas)
            XCTAssertEqual(cells.count, count)
            for (i, cell) in cells.enumerated() {
                XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(cell))
                for other in cells[(i + 1)...] { XCTAssertFalse(cell.intersects(other), "\(count) cells overlap") }
            }
        }
    }

    func testEvenlyKeepsShortRunsWhole() {
        XCTAssertEqual(RecapPlan.evenly([1, 2, 3], count: 5), [1, 2, 3])
        XCTAssertEqual(RecapPlan.evenly(Array(0..<10), count: 4), [0, 3, 6, 9])
        XCTAssertEqual(RecapPlan.evenly(Array(0..<10), count: 1), [0])
    }

    private func pictures(in recap: RecapPlan) -> [Moment] {
        recap.slides.flatMap { slide -> [Moment] in
            if case .pictures(let moments) = slide { return moments }
            return []
        }
    }

    func testTheTwelveMonthRunEndsNow() throws {
        let now = day(2026, 11, 9)
        let moments = [Fixtures.moment("in", at: day(2025, 12, 1)), Fixtures.moment("out", at: day(2025, 10, 1))]
        let recap = try XCTUnwrap(plan(.lastTwelveMonths, moments: moments, now: now))
        XCTAssertEqual(recap.interval.end, now)
        XCTAssertEqual(recap.slides.count, 3)
    }

    /// The index keeps the newest 500; only a period reaching past a full one needs iCloud.
    func testOnlyAPeriodPastAFullIndexNeedsTheZone() {
        let year = RecapPlan.Period.year(2026).interval(calendar: calendar)
        let short = [Fixtures.moment("a", at: day(2026, 6, 1))]
        XCTAssertFalse(RecapPlan.needsZone(index: short, interval: year, limit: 3), "not full: it's everything")
        let full = (0..<3).map { Fixtures.moment("m\($0)", at: day(2026, 6, 1 + $0)) }
        XCTAssertTrue(RecapPlan.needsZone(index: full, interval: year, limit: 3), "older ones may have been dropped")
        let reachesBack = full + [Fixtures.moment("old", at: day(2025, 12, 1))]
        XCTAssertFalse(RecapPlan.needsZone(index: reachesBack, interval: year, limit: 3),
                       "the index already reaches back past the year")
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Midday on Christmas Day, only while paired and once the year has a picture;
    /// gone once it's fired, and never for a year already opened or waved away.
    func testTheReminderComesAtChristmasMidday() throws {
        func reminder(paired: Bool = true, pictures: Bool = true, dismissed: Int? = nil,
                      now: Date) -> RecapPlan.Reminder? {
            RecapPlan.reminder(paired: paired, hasPictures: { _ in pictures }, dismissed: dismissed,
                               now: now, calendar: calendar)
        }
        let due = try XCTUnwrap(reminder(now: day(2026, 3, 1)))
        XCTAssertEqual(due.year, 2026)
        XCTAssertEqual(due.identifier, "recap-2026")
        XCTAssertEqual(due.fireAt, DateComponents(calendar: Calendar(identifier: .gregorian),
                                                  year: 2026, month: 12, day: 25, hour: 12, minute: 0))
        XCTAssertNil(due.fireAt.timeZone, "floats with the phone")
        XCTAssertNotNil(reminder(now: at(2026, 12, 25, 11)))
        XCTAssertNil(reminder(paired: false, now: day(2026, 3, 1)))
        XCTAssertNil(reminder(pictures: false, now: day(2026, 3, 1)))
        XCTAssertNil(reminder(dismissed: 2026, now: day(2026, 3, 1)))
        XCTAssertNil(reminder(now: at(2026, 12, 25, 12)), "already fired")
    }

    /// A gift: nothing shows the year's recap before it unwraps.
    func testHomeOffersItFromChristmasMiddayThroughJanuary() {
        XCTAssertNil(RecapPlan.yearOnOffer(now: at(2026, 12, 1, 9), calendar: calendar))
        XCTAssertNil(RecapPlan.yearOnOffer(now: at(2026, 12, 25, 11), calendar: calendar))
        XCTAssertEqual(RecapPlan.yearOnOffer(now: at(2026, 12, 25, 12), calendar: calendar), 2026)
        XCTAssertEqual(RecapPlan.yearOnOffer(now: day(2027, 1, 31), calendar: calendar), 2026)
        XCTAssertNil(RecapPlan.yearOnOffer(now: day(2027, 2, 1), calendar: calendar))
    }

    func testSettingsShowsTheLastFullYearUntilItUnwraps() {
        XCTAssertEqual(RecapPlan.reviewYear(now: day(2026, 11, 9), calendar: calendar), 2025)
        XCTAssertEqual(RecapPlan.reviewYear(now: at(2026, 12, 25, 11), calendar: calendar), 2025)
        XCTAssertEqual(RecapPlan.reviewYear(now: at(2026, 12, 25, 12), calendar: calendar), 2026)
        XCTAssertEqual(RecapPlan.reviewYear(now: day(2027, 1, 15), calendar: calendar), 2026)
    }

    /// The year and Christmas are Gregorian whatever calendar the phone shows.
    func testTheRecapCalendarIsGregorian() {
        XCTAssertEqual(RecapPlan.gregorian.identifier, .gregorian)
        let year = RecapPlan.Period.year(2026).interval()
        let parts = RecapPlan.gregorian.dateComponents([.year, .month, .day], from: year.start)
        XCTAssertEqual([parts.year, parts.month, parts.day], [2026, 1, 1])
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertNotEqual(RecapPlan.Period.year(2026).interval(calendar: hebrew).start, year.start,
                          "which is why every default is the Gregorian one")
    }

    /// Only a picture this phone held makes a kept recap stale: not a memo,
    /// nor our own delete echoing back after it already left the index.
    func testOnlyAHeldPictureDeletionInvalidates() {
        let known = [Fixtures.moment("photo"), Fixtures.moment("memo", kind: .voice)]
        XCTAssertTrue(RecapPlan.invalidates(removed: ["photo"], known: known))
        XCTAssertFalse(RecapPlan.invalidates(removed: ["memo"], known: known))
        XCTAssertFalse(RecapPlan.invalidates(removed: ["already-gone"], known: known))
    }
}
