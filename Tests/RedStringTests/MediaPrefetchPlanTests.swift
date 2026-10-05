import XCTest

/// What each process downloads after a refresh files new moments — run after
/// the change token is persisted (invariant 2), so the notification service's
/// banner never waits on a backlog of photos.
final class MediaPrefetchPlanTests: XCTestCase {
    /// `n` moments, newest first, ids `m0` (newest) … ; every third is a memo when `mixed`.
    private func arrived(_ n: Int, mixed: Bool = false) -> [Moment] {
        (0..<n).map { index in
            let kind: Moment.Kind = mixed && index % 3 == 1 ? .voice : .photo
            let sentAt = Fixtures.date(TimeInterval(-index * 60))
            return Fixtures.moment("m\(index)", kind: kind, at: sentAt, fromMe: index % 4 == 3)
        }
    }

    private func plan(_ moments: [Moment],
                      recent: [Moment] = [],
                      in process: MediaPrefetchPlan.Process,
                      cachedMedia: Set<String> = [],
                      cachedThumbnails: Set<String> = []) -> [MediaPrefetchPlan.Item] {
        MediaPrefetchPlan.items(for: moments,
                                recent: recent,
                                in: process,
                                hasMedia: { cachedMedia.contains($0.id) },
                                hasThumbnail: { cachedThumbnails.contains($0.id) })
    }

    // MARK: App

    func testAppTakesTheTenNewestInFull() {
        let items = plan(arrived(14, mixed: true).shuffled(), in: .app)
        XCTAssertEqual(items.map(\.moment.id), (0..<10).map { "m\($0)" }, "newest first, whatever order they arrived in")
        XCTAssertTrue(items.allSatisfy { $0.fetch == .full })
        XCTAssertTrue(items.contains { $0.moment.isVoice }, "a memo's recording is fetched like a photo")
        XCTAssertTrue(items.contains { $0.moment.fromMe }, "own sends from another device too")
    }

    func testAppSkipsWhatIsOnDiskButStillCountsItAgainstTheCap() {
        let items = plan(arrived(12), in: .app, cachedMedia: ["m0", "m5"])
        XCTAssertEqual(items.map(\.moment.id), ["m1", "m2", "m3", "m4", "m6", "m7", "m8", "m9"],
                       "the cap is over the newest arrived, not the newest missing")
    }

    /// The notification service usually files a push's moments first, so the
    /// app's own refresh sees nothing arrive; the index's newest still get fetched.
    func testAppAlsoCoversTheIndexsNewest() {
        let filedElsewhere = arrived(3)
        let items = plan([], recent: filedElsewhere, in: .app)
        XCTAssertEqual(items.map(\.moment.id), ["m0", "m1", "m2"])
        let both = plan([filedElsewhere[0]], recent: filedElsewhere, in: .app)
        XCTAssertEqual(both.map(\.moment.id), ["m0", "m1", "m2"], "a moment in both is fetched once")
    }

    // MARK: Widget

    /// What it draws: the partner's newest photo or doodle (`latestPartnerVisualMoment`).
    func testWidgetTakesThumbnailsOfThePartnersThreeNewestVisualMoments() {
        let items = plan(arrived(8, mixed: true), in: .widget)
        XCTAssertEqual(items.map(\.moment.id), ["m0", "m2", "m5"], "m1/m4 are memos, m3 our own")
        XCTAssertTrue(items.allSatisfy { $0.fetch == .thumbnail })
    }

    func testWidgetNeverFetchesVoiceAndMemosDontCrowdOutPhotos() {
        let memos = (0..<3).map {
            Fixtures.moment("v\($0)", kind: .voice, at: Fixtures.date(-TimeInterval($0)))
        }
        let photo = Fixtures.moment("p", at: Fixtures.date(-60))
        let items = plan(memos + [photo], in: .widget)
        XCTAssertEqual(items, [.init(moment: photo, fetch: .thumbnail)],
                       "the widget draws the newest photo, however many memos came after it")
        XCTAssertTrue(plan(memos, in: .widget).isEmpty)
    }

    func testWidgetSkipsCachedThumbnailsWithinTheCap() {
        let items = plan(arrived(5), in: .widget, cachedMedia: ["m0"], cachedThumbnails: ["m1"])
        XCTAssertEqual(items.map(\.moment.id), ["m0", "m2"],
                       "only the thumbnail counts as cached for the widget; m4 is past the cap")
    }

    // MARK: Notification service

    /// Only the widget's picture: after a photo-then-memo burst the banner
    /// attaches the memo, and nothing else would fetch the photo's thumbnail.
    func testNotificationServiceTakesOnlyTheWidgetsThumbnail() {
        let memo = Fixtures.moment("memo", kind: .voice, at: Fixtures.date(10))
        let own = Fixtures.moment("own", at: Fixtures.date(5), fromMe: true)
        let photo = Fixtures.moment("photo", at: Fixtures.t0)
        let older = Fixtures.moment("older", at: Fixtures.date(-60))
        XCTAssertEqual(plan([memo, own, photo, older], in: .notificationService),
                       [.init(moment: photo, fetch: .thumbnail)])
        XCTAssertTrue(plan([memo, own, photo], in: .notificationService, cachedThumbnails: ["photo"]).isEmpty)
        XCTAssertTrue(plan([memo, own], in: .notificationService).isEmpty, "never a full photo, never audio")
    }

    func testEmptyDeltaPlansNothingAnywhere() {
        for process in [MediaPrefetchPlan.Process.app, .widget, .notificationService] {
            XCTAssertTrue(plan([], in: process).isEmpty)
        }
    }

    // MARK: The banner's attachment

    func testAttachmentIsTheThumbnailOrTheRecording() {
        XCTAssertEqual(MediaPrefetchPlan.attachment(for: Fixtures.moment("p", kind: .photo)), .thumbnail)
        XCTAssertEqual(MediaPrefetchPlan.attachment(for: Fixtures.moment("d", kind: .drawing)), .thumbnail)
        XCTAssertEqual(MediaPrefetchPlan.attachment(for: Fixtures.moment("v", kind: .voice)), .full)
    }

    // MARK: The library's backfill after a full resync

    func testBackfillTakesEveryMissingPictureNewestFirst() {
        let index = [
            Fixtures.moment("old", at: Fixtures.date(-600)),
            Fixtures.moment("memo", kind: .voice, at: Fixtures.date(-60)),
            Fixtures.moment("cached", at: Fixtures.date(-30)),
            Fixtures.moment("pending", at: Fixtures.date(-20), fromMe: true, uploaded: false),
            Fixtures.moment("mine", kind: .drawing, at: Fixtures.date(-10), fromMe: true),
            Fixtures.moment("new", at: Fixtures.t0),
        ]
        let missing = MediaPrefetchPlan.missingThumbnails(in: index, hasThumbnail: { $0.id == "cached" })
        XCTAssertEqual(missing.map(\.id), ["new", "mine", "old"],
                       "no memos, nothing on disk, and no unsent own send — the server hasn't got it")
    }
}
