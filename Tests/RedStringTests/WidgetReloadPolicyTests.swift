import XCTest

/// The widget's next-refresh schedule: hourly when caught up, soon while a
/// locked phone's pushes sit unread, backing off the longer they wait.
final class WidgetReloadPolicyTests: XCTestCase {
    private let now = Fixtures.date(24 * 60 * 60)

    private func delay(heldFor waited: TimeInterval?, incomplete: Bool = false) -> TimeInterval {
        let heldSince = waited.map { now.addingTimeInterval(-$0) }
        return WidgetReloadPolicy.nextReload(heldSince: heldSince, incomplete: incomplete, now: now)
            .timeIntervalSince(now)
    }

    func testCaughtUpIsHourly() {
        XCTAssertEqual(delay(heldFor: nil), WidgetReloadPolicy.settled)
    }

    func testIncompleteBatchComesBackSoon() {
        XCTAssertEqual(delay(heldFor: nil, incomplete: true), 5 * 60)
    }

    func testHeldRecordsBackOff() {
        XCTAssertEqual(delay(heldFor: 0), 5 * 60)
        XCTAssertEqual(delay(heldFor: 29 * 60), 5 * 60)
        XCTAssertEqual(delay(heldFor: 30 * 60), 15 * 60)
        XCTAssertEqual(delay(heldFor: 2 * 60 * 60), 30 * 60)
        XCTAssertEqual(delay(heldFor: 3 * 24 * 60 * 60), 30 * 60, "never gives up while held")
    }

    /// A phone locked for eight hours after a push stays well inside WidgetKit's
    /// daily reload budget (roughly 40–70 per widget).
    func testOvernightLockStaysInBudget() {
        let start = now
        var clock = start
        var reloads = 0
        while clock.timeIntervalSince(start) < 8 * 60 * 60 {
            clock = WidgetReloadPolicy.nextReload(heldSince: start, incomplete: false, now: clock)
            reloads += 1
        }
        XCTAssertLessThanOrEqual(reloads, 25)
    }

    func testHeldBeatsIncomplete() {
        XCTAssertEqual(delay(heldFor: 3 * 60 * 60, incomplete: true), 30 * 60)
    }
}
