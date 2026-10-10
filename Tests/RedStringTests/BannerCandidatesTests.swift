import XCTest

/// The NSE hands `PushBannerPolicy` only the index entries past the announced
/// floor — never fewer than the moment claim's own fallback would consider.
final class BannerCandidatesTests: XCTestCase {
    private let now = Fixtures.date(1_000)

    private var index: [Moment] {
        [Fixtures.moment("new", at: Fixtures.date(500)),
         Fixtures.moment("mine", at: Fixtures.date(600), fromMe: true),
         Fixtures.moment("old", at: Fixtures.date(100))]
    }

    func testOnlyThePartnersPastTheFloor() {
        let kept = AnnouncementPolicy.bannerCandidates(index, floor: Fixtures.date(200), now: now)
        XCTAssertEqual(kept.map(\.id), ["new"])
        XCTAssertEqual(AnnouncementPolicy.bannerCandidates(index, floor: nil, now: now).map(\.id), ["new", "old"])
    }

    func testAFloorAheadOfTheClockKeepsWhatTheClaimWould() {
        let stuck = now.addingTimeInterval(AppConfig.clockSkewAllowance + 60)
        var snapshot = Snapshot.empty
        snapshot.lastAnnouncedMomentSentAt = stuck
        let late = Fixtures.moment("late", at: now.addingTimeInterval(30))
        let all = index + [late]
        let kept = AnnouncementPolicy.bannerCandidates(all, floor: stuck, now: now)
        XCTAssertEqual(kept.map(\.id), ["late"], "read as now, like the claim")
        let claimed = AnnouncementPolicy.claimMomentBanner(delta: [], index: kept, in: &snapshot, now: now)
        XCTAssertEqual(claimed?.id, "late")
    }

    func testTheClaimChoosesTheSameFromTheCandidates() {
        for floor in [nil, Fixtures.date(50), Fixtures.date(200), Fixtures.date(700)] {
            var full = Snapshot.empty
            full.lastAnnouncedMomentSentAt = floor
            var filtered = full
            let fromAll = AnnouncementPolicy.claimMomentBanner(delta: [], index: index, in: &full, now: now)
            let candidates = AnnouncementPolicy.bannerCandidates(index, floor: floor, now: now)
            let fromCandidates = AnnouncementPolicy.claimMomentBanner(delta: [], index: candidates,
                                                                      in: &filtered, now: now)
            XCTAssertEqual(fromAll?.id, fromCandidates?.id)
        }
    }
}
