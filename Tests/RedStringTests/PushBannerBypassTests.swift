import CloudKit
import UserNotifications
import XCTest

/// The notification service's exits before any plan (`PushBannerPolicy.Bypass`):
/// a locked phone's store, an unlinked phone, a failed refresh (STORE-1).
final class PushBannerBypassTests: XCTestCase {
    private let pairing = PairingInfo(role: .owner, zoneName: AppConfig.coupleZoneName,
                                      zoneOwnerName: CKCurrentUserDefaultName, pairedAt: Fixtures.t0)

    private func content(_ push: PushBannerPolicy.Push) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "CloudKit's title"
        content.body = "CloudKit's words"
        content.categoryIdentifier = push.category
        content.sound = .default
        return content
    }

    func testOnlyAReadablePairedStoreGoesOnToRefresh() {
        XCTAssertNil(PushBannerPolicy.Bypass(isCloudKitPush: true, pairing: .paired(pairing)))
        XCTAssertEqual(PushBannerPolicy.Bypass(isCloudKitPush: true, pairing: .unpaired), .unpaired)
        XCTAssertEqual(PushBannerPolicy.Bypass(isCloudKitPush: true, pairing: .unreadable), .unreadable)
        XCTAssertEqual(PushBannerPolicy.Bypass(isCloudKitPush: false, pairing: .paired(pairing)), .notCloudKit)
    }

    func testARefreshErrorIsSortedByWhatItSays() {
        XCTAssertEqual(PushBannerPolicy.Bypass(after: SyncError.storeUnreadable), .unreadable)
        XCTAssertEqual(PushBannerPolicy.Bypass(after: SyncError.notPaired), .unpaired)
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual(PushBannerPolicy.Bypass(after: offline), .failed(offline.localizedDescription))
    }

    /// Before first unlock: CloudKit's words go out unchanged, held, so whatever
    /// reads first rewords them — never the unlinked look.
    func testAnUnreadableStoreKeepsCloudKitsWordsHeld() {
        let banner = content(.status)
        let (outcome, detail) = PushBannerPolicy.Bypass.unreadable.apply(to: banner, push: .status)

        XCTAssertEqual(outcome, .unworded)
        XCTAssertEqual(detail, "store unreadable")
        XCTAssertEqual(banner.body, "CloudKit's words")
        XCTAssertEqual(banner.categoryIdentifier, NotificationCategory.status, "still the partner's, actions kept")
        XCTAssertNotNil(banner.sound, "full volume: a real, unannounced event")
        XCTAssertEqual(banner.userInfo[BannerSubject.key] as? String, BannerSubject.status.stamp)
        XCTAssertEqual(banner.userInfo[NotificationCategory.heldBannerKey] as? String, NotificationCategory.status)
        XCTAssertTrue(PushBannerPolicy.Bypass.unreadable.widgetNeedsFetch)
    }

    func testAMomentPushHeldUnreadableIsFoundAgainAsNewMoments() {
        let banner = content(.moment)
        _ = PushBannerPolicy.Bypass.unreadable.apply(to: banner, push: .moment)
        XCTAssertEqual(banner.userInfo[BannerSubject.key] as? String, BannerSubject.newMoments.stamp)
    }

    /// A heart has nothing to reword it into: it keeps CloudKit's words, unstamped.
    func testAHeartHeldUnreadableIsLeftAsItCame() {
        let banner = content(.nudge)
        _ = PushBannerPolicy.Bypass.failed("offline").apply(to: banner, push: .nudge)
        XCTAssertNil(banner.userInfo[BannerSubject.key])
        XCTAssertNil(banner.userInfo[NotificationCategory.heldBannerKey])
    }

    func testAnUnlinkedPhonesPushIsQuietNeutralAndActionless() {
        let banner = content(.nudge)
        let (outcome, _) = PushBannerPolicy.Bypass.unpaired.apply(to: banner, push: .nudge)

        XCTAssertEqual(outcome, .worded)
        XCTAssertEqual(banner.title, AppConfig.appName)
        XCTAssertEqual(banner.categoryIdentifier, "", "no heart to send back")
        XCTAssertNil(banner.sound)
        XCTAssertEqual(banner.interruptionLevel, .passive)
        XCTAssertFalse(PushBannerPolicy.Bypass.unpaired.widgetNeedsFetch, "nothing to fetch")
    }

    func testAPushNotFromCloudKitIsDeliveredAsItCame() {
        let banner = content(.other)
        let (outcome, _) = PushBannerPolicy.Bypass.notCloudKit.apply(to: banner, push: .other)
        XCTAssertEqual(outcome, .unworded)
        XCTAssertEqual(banner.body, "CloudKit's words")
        XCTAssertTrue(banner.userInfo.isEmpty)
    }
}
