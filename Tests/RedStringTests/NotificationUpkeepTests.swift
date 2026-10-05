import CloudKit
import XCTest

/// The small rules around notifications outside the banner table: the
/// unpaired subscription cleanup's success test, the shared account cache's
/// lifetime, and the per-device switches' defaults.
final class NotificationUpkeepTests: XCTestCase {
    func testCleanupCountsNothingToDeleteAsDone() {
        XCTAssertTrue(CloudSync.subscriptionsGone([:]))
        XCTAssertTrue(CloudSync.subscriptionsGone([
            CloudSync.SubscriptionID.status: .success(()),
            CloudSync.SubscriptionID.nudge: .failure(CKError(.unknownItem)),
        ]))
        XCTAssertFalse(CloudSync.subscriptionsGone([
            CloudSync.SubscriptionID.moment: .failure(CKError(.networkUnavailable)),
        ]), "still registered: the ex's writes would keep pushing here")
    }

    func testTheSharedAccountCacheIsTrustedOnlyWithinItsLifetime() {
        let now = Fixtures.t0
        XCTAssertTrue(CloudSync.isFresh(now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(CloudSync.isFresh(now.addingTimeInterval(-CloudSync.accountCacheLifetime), now: now))
        XCTAssertFalse(CloudSync.isFresh(now.addingTimeInterval(60), now: now), "stamped in the future")
    }

    func testSwitchesAndMarksRoundTrip() {
        let store = SharedStore(defaults: temporaryDefaults())
        XCTAssertFalse(store.milestoneRemindersEnabled, "off by default")
        store.milestoneRemindersEnabled = true
        XCTAssertTrue(store.milestoneRemindersEnabled)

        XCTAssertNil(store.subscriptionCleanup)
        let cleanup = SharedStore.SubscriptionCleanup(userRecordName: "_abc", since: Fixtures.t0)
        store.subscriptionCleanup = cleanup
        XCTAssertEqual(store.subscriptionCleanup, cleanup)
        store.subscriptionCleanup = nil
        XCTAssertNil(store.subscriptionCleanup)

        let account = SharedStore.VerifiedAccount(name: "_abc", verifiedAt: Fixtures.t0)
        store.verifiedAccount = account
        XCTAssertEqual(store.verifiedAccount, account)
        store.verifiedAccount = nil
        XCTAssertNil(store.verifiedAccount)
    }

    /// A test store's own reloads stamp it — never the real container.
    func testAReloadStampsTheStoreThatAskedForIt() throws {
        let store = SharedStore(defaults: temporaryDefaults())
        store.requestWidgetReload()
        let stamped = try XCTUnwrap(store.widgetReloadRequestedAt)
        XCTAssertLessThan(Date().timeIntervalSince(stamped), 5)
        store.requestWidgetReload(widgetNeedsFetch: true)
        XCTAssertNil(store.widgetReloadRequestedAt)
    }

    func testAHeldProcessAbsorbsReloadsUntilTheHoldEnds() {
        let store = SharedStore(defaults: temporaryDefaults())
        let hold = store.holdWidgetReloads()
        store.requestWidgetReload()
        XCTAssertNil(store.widgetReloadRequestedAt, "absorbed while held")
        hold.release(widgetNeedsFetch: true)
        store.requestWidgetReload()
        XCTAssertNotNil(store.widgetReloadRequestedAt)
    }
}
