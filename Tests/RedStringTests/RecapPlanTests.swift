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
        let ids = recap.slides.compactMap { slide -> String? in
            if case .picture(let moment) = slide { return moment.id }
            return nil
        }
        XCTAssertEqual(ids, ["photo", "doodle"], "date order; no memo, newer kind or other year")
        XCTAssertEqual(recap.momentCount, 3, "the tally counts the memo, not a kind this build can't show")
    }

    func testNoPicturesNoRecap() {
        XCTAssertNil(plan(.year(2026), moments: [Fixtures.moment("memo", kind: .voice, at: day(2026, 3, 1))],
                          statuses: [entry("hi", at: day(2026, 3, 2))]))
    }

    func testStatusesInterleaveByDate() throws {
        let moments = [Fixtures.moment("a", at: day(2026, 1, 10)), Fixtures.moment("b", at: day(2026, 6, 10))]
        let statuses = [entry("spring", at: day(2026, 3, 1)), entry("last year", at: day(2025, 6, 1)),
                        StatusHistoryEntry(emoji: "", message: "  ", isCelebration: false,
                                           at: day(2026, 4, 1), fromMe: true)]
        let recap = try XCTUnwrap(plan(.year(2026), moments: moments, statuses: statuses))
        XCTAssertEqual(recap.slides, [.opening, .picture(moments[0]), .status(statuses[0]),
                                      .picture(moments[1]), .closing])
        XCTAssertEqual(recap.statusCount, 2, "a blank status counts, but isn't drawn")
    }

    /// A busy year stays near 90 seconds, spread across the whole year.
    func testABusyYearIsCappedEvenly() throws {
        let moments = (0..<300).map { Fixtures.moment("m\($0)", at: day(2026, 1, 1).addingTimeInterval(Double($0) * 86_400)) }
        let statuses = (0..<100).map { entry("s\($0)", at: day(2026, 1, 2).addingTimeInterval(Double($0) * 3 * 86_400)) }
        let recap = try XCTUnwrap(plan(.year(2026), moments: moments, statuses: statuses))
        let pictures = recap.slides.compactMap { slide -> Moment? in
            if case .picture(let moment) = slide { return moment }
            return nil
        }
        XCTAssertEqual(pictures.count, RecapPlan.maxPictures)
        XCTAssertEqual(pictures.first?.id, "m0")
        XCTAssertEqual(pictures.last?.id, "m299")
        XCTAssertEqual(recap.slides.filter { if case .status = $0 { true } else { false } }.count, RecapPlan.maxStatuses)
        XCTAssertLessThanOrEqual(recap.duration, 95)
        XCTAssertEqual(recap.momentCount, 300)
    }

    func testEvenlyKeepsShortRunsWhole() {
        XCTAssertEqual(RecapPlan.evenly([1, 2, 3], count: 5), [1, 2, 3])
        XCTAssertEqual(RecapPlan.evenly(Array(0..<10), count: 4), [0, 3, 6, 9])
        XCTAssertEqual(RecapPlan.evenly(Array(0..<10), count: 1), [0])
    }

    func testTheTwelveMonthRunEndsNow() throws {
        let now = day(2026, 11, 9)
        let moments = [Fixtures.moment("in", at: day(2025, 12, 1)), Fixtures.moment("out", at: day(2025, 10, 1))]
        let recap = try XCTUnwrap(plan(.lastTwelveMonths, moments: moments, now: now))
        XCTAssertEqual(recap.interval.end, now)
        XCTAssertEqual(recap.slides.count, 3)
    }

    func testHomeOffersDecemberThroughJanuary() {
        XCTAssertEqual(RecapPlan.yearOnOffer(now: day(2026, 12, 1), calendar: calendar), 2026)
        XCTAssertEqual(RecapPlan.yearOnOffer(now: day(2027, 1, 31), calendar: calendar), 2026)
        XCTAssertNil(RecapPlan.yearOnOffer(now: day(2026, 11, 30), calendar: calendar))
        XCTAssertNil(RecapPlan.yearOnOffer(now: day(2027, 2, 1), calendar: calendar))
    }

    func testSettingsShowsTheLastFullYearUntilDecember() {
        XCTAssertEqual(RecapPlan.reviewYear(now: day(2026, 11, 9), calendar: calendar), 2025)
        XCTAssertEqual(RecapPlan.reviewYear(now: day(2026, 12, 1), calendar: calendar), 2026)
        XCTAssertEqual(RecapPlan.reviewYear(now: day(2027, 1, 15), calendar: calendar), 2026)
    }
}
