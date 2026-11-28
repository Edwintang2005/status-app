import XCTest

/// The photo widget's Favourites: which pictures, and which one a day.
final class WidgetFavouritesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9))!)!
    }

    func testEveryFavouriteShowsOnceBeforeAnyRepeats() {
        for count in [3, 5, 12] {
            for start in [0, 7, 40] {
                let firstCycleStart = (0..<count).first { offset in
                    let index = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0),
                                                        to: calendar.startOfDay(for: day(start + offset))).day!
                    return index % count == 0
                }!
                let picks = (0..<count).map { WidgetFavourites.pick(count: count, on: day(start + firstCycleStart + $0), calendar: calendar)! }
                XCTAssertEqual(Set(picks).count, count, "a cycle of \(count) shows each once")
            }
        }
    }

    func testNeverTheSamePictureTwoDaysRunning() {
        for count in [2, 3, 4, 7] {
            let picks = (0..<200).map { WidgetFavourites.pick(count: count, on: day($0), calendar: calendar)! }
            for (yesterday, today) in zip(picks, picks.dropFirst()) {
                XCTAssertNotEqual(yesterday, today, "\(count) favourites")
            }
        }
        XCTAssertEqual(WidgetFavourites.pick(count: 1, on: day(0), calendar: calendar), 0)
        XCTAssertNil(WidgetFavourites.pick(count: 0, on: day(0), calendar: calendar))
    }

    func testTheSameDayAlwaysPicksTheSame() {
        let morning = day(3), night = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day(3))!
        XCTAssertEqual(WidgetFavourites.pick(count: 9, on: morning, calendar: calendar),
                       WidgetFavourites.pick(count: 9, on: night, calendar: calendar))
    }

    func testStarredPicturesFromEitherSideOldestStarFirst() {
        var mine = Fixtures.moment("mine", at: Fixtures.date(10)); mine.fromMe = true; mine.favouritedAt = Fixtures.date(300)
        var theirs = Fixtures.moment("theirs", at: Fixtures.date(20)); theirs.favouritedAt = Fixtures.date(200)
        var memo = Fixtures.moment("memo", at: Fixtures.date(30)); memo.kind = .voice; memo.favouritedAt = Fixtures.date(100)
        let plain = Fixtures.moment("plain", at: Fixtures.date(40))
        var hidden = Fixtures.moment("hidden", at: Fixtures.date(50)); hidden.favouritedAt = Fixtures.date(50)
        let favourites = WidgetFavourites.derive(from: [mine, theirs, memo, plain, hidden], hidden: ["hidden"])
        XCTAssertEqual(favourites.map(\.id), ["theirs", "mine"], "pictures only, never one taken off the widget")
    }

    // MARK: What the widget draws

    private func content(unseen: Bool, favourites: [String]) -> WidgetContent {
        var snapshot = Snapshot.empty
        var latest = Fixtures.moment("latest", at: Fixtures.date(900))
        latest.seen = !unseen
        snapshot.latestPartnerVisualMoment = latest
        snapshot.widgetFavourites = favourites.map { id in
            var moment = Fixtures.moment(id, at: Fixtures.date(1))
            moment.favouritedAt = Fixtures.date(2)
            return moment
        }
        return WidgetContent(drawing: snapshot)
    }

    func testLatestIsTheDefaultAndFavouritesShowAStarredOne() {
        let both = content(unseen: false, favourites: ["f1", "f2", "f3"])
        XCTAssertEqual(both.picture(favourites: false, on: day(0), calendar: calendar)?.id, "latest")
        XCTAssertTrue(["f1", "f2", "f3"].contains(both.picture(favourites: true, on: day(0), calendar: calendar)!.id))
    }

    func testANewPictureFromThemStillShowsFirst() {
        let unseen = content(unseen: true, favourites: ["f1", "f2"])
        XCTAssertEqual(unseen.picture(favourites: true, on: day(0), calendar: calendar)?.id, "latest",
                       "they sent you something: that comes before the favourites")
    }

    func testNoFavouritesYetShowsTheLatest() {
        let none = content(unseen: false, favourites: [])
        XCTAssertEqual(none.picture(favourites: true, on: day(0), calendar: calendar)?.id, "latest")
    }

    /// Invariant 6: starring changes what's drawn, so the widgets reload.
    func testAFavouriteIsPartOfWhatTheWidgetsDraw() {
        XCTAssertNotEqual(content(unseen: false, favourites: []), content(unseen: false, favourites: ["f1"]))
    }
}
