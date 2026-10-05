import XCTest

/// What one `getTimeline` answers (entries, the heart's flip-backs, the next
/// reload), when a reload needs the widget's own fetch, and the one refresh
/// every kind in the process shares.
final class WidgetTimelineTests: XCTestCase {
    private let now = Fixtures.date(24 * 60 * 60)

    // MARK: Sibling reloads

    func testAReloadASiblingAskedForDoesNotFetch() {
        let stale = now.addingTimeInterval(-3600)
        XCTAssertFalse(WidgetReloadPolicy.shouldFetch(lastSyncedAt: stale,
                                                      reloadRequestedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(WidgetReloadPolicy.shouldFetch(lastSyncedAt: stale,
                                                     reloadRequestedAt: now.addingTimeInterval(-3 * 60), now: now),
                      "WidgetKit deferring the reload past the window just means a fetch, as before")
        XCTAssertTrue(WidgetReloadPolicy.shouldFetch(lastSyncedAt: stale, reloadRequestedAt: nil, now: now),
                      "a reload that needs a fetch (one batch, a refresh that failed) clears the stamp")
        XCTAssertTrue(WidgetReloadPolicy.shouldFetch(lastSyncedAt: stale,
                                                     reloadRequestedAt: now.addingTimeInterval(600), now: now),
                      "a stamp from the future is a skewed clock")
    }

    func testTheWindowIsShorterThanAnyTimerReload() {
        let soonest = WidgetReloadPolicy.nextReload(heldSince: nil, incomplete: true, now: now).timeIntervalSince(now)
        XCTAssertLessThan(WidgetReloadPolicy.siblingReloadWindow, soonest)
    }

    // MARK: Timeline plan

    func testCaughtUpIsOneEntryAndHourly() {
        let plan = TimelinePlan(lastNudgeSentAt: nil, lastNudgeFailedAt: nil, heldSince: nil,
                                incomplete: false, now: now)
        XCTAssertEqual(plan.entries, [now])
        XCTAssertEqual(plan.nextReload, now.addingTimeInterval(WidgetReloadPolicy.settled))
    }

    func testTheHeartFlipsBackWhereItsCooldownAndFailureEnd() {
        let sent = now.addingTimeInterval(-1)
        let failed = now.addingTimeInterval(-2)
        let plan = TimelinePlan(lastNudgeSentAt: sent, lastNudgeFailedAt: failed, heldSince: nil,
                                incomplete: false, now: now)
        XCTAssertEqual(plan.entries.first, now)
        XCTAssertTrue(plan.entries.contains(sent.addingTimeInterval(AppConfig.nudgeCooldown)))
        XCTAssertTrue(plan.entries.contains(failed.addingTimeInterval(AppConfig.nudgeFailureNotice)))
        XCTAssertEqual(plan.entries, plan.entries.sorted(), "WidgetKit expects them in order")
    }

    func testExpiredNoticesAddNothing() {
        let long = now.addingTimeInterval(-24 * 60 * 60)
        let plan = TimelinePlan(lastNudgeSentAt: long, lastNudgeFailedAt: long, heldSince: nil,
                                incomplete: false, now: now)
        XCTAssertEqual(plan.entries, [now])
    }

    func testThePlanTakesThePolicysNextReload() {
        let held = TimelinePlan(lastNudgeSentAt: nil, lastNudgeFailedAt: nil, heldSince: now,
                                incomplete: false, now: now)
        XCTAssertEqual(held.nextReload, WidgetReloadPolicy.nextReload(heldSince: now, incomplete: false, now: now))
        let batch = TimelinePlan(lastNudgeSentAt: nil, lastNudgeFailedAt: nil, heldSince: nil,
                                 incomplete: true, now: now)
        XCTAssertEqual(batch.nextReload, now.addingTimeInterval(5 * 60))
    }

    // MARK: Single flight

    func testConcurrentCallersShareOneRun() async {
        let flight = SingleFlight<Int>()
        let runs = Counter()
        let gate = Gate()
        async let first = flight.run {
            await runs.increment()
            await gate.wait()
            return 7
        }
        // Let the first run start before the others join it.
        while await runs.value == 0 { await Task.yield() }
        async let second = flight.run { await runs.increment(); return 1 }
        async let third = flight.run { await runs.increment(); return 2 }
        // Give the joiners time to reach the flight before it lands.
        try? await Task.sleep(for: .milliseconds(200))
        await gate.open()
        let values = await [first, second, third]
        XCTAssertEqual(values, [7, 7, 7])
        let count = await runs.value
        XCTAssertEqual(count, 1)

        let later = await flight.run { await runs.increment(); return 9 }
        XCTAssertEqual(later, 9, "once landed, the next caller starts a new run")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func testMarkingSeenIsNoChangeTheWidgetsDraw() {
        var before = Snapshot.empty
        var moment = Moment(kind: .photo, caption: "hi", senderName: "Sam", fromMe: false)
        before.latestPartnerMoment = moment
        before.latestPartnerVisualMoment = moment
        var after = before
        moment.seen = true
        after.latestPartnerMoment = moment
        after.latestPartnerVisualMoment = moment
        XCTAssertEqual(SharedStore.Derived(before), SharedStore.Derived(after), "no pixel moved")
        moment.caption = "hello"
        after.latestPartnerVisualMoment = moment
        XCTAssertNotEqual(SharedStore.Derived(before), SharedStore.Derived(after), "a caption that became readable redraws")
    }
}
