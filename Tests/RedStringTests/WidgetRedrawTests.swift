import XCTest

/// `mutate` reloads the widgets exactly when what they draw moves (invariant 6).
/// Every stored field of the snapshot, a status and a moment is walked: a new
/// field fails here until it's classified, and its class is then checked.
final class WidgetRedrawTests: XCTestCase {
    private typealias Change = (inout Snapshot) -> Void

    private var base: Snapshot {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.mine = Fixtures.status("☕️", "up early", at: Fixtures.date(-60))
        snapshot.theirs = Fixtures.status()
        var picture = Fixtures.moment("p1")
        picture.caption = "morning"
        snapshot.latestPartnerVisualMoment = picture
        snapshot.latestPartnerMoment = picture
        snapshot.unheardVoiceMemoCount = 1
        return snapshot
    }

    /// Whether `change`, from `start`, asked for a reload. It must change something.
    private func redraws(from start: Snapshot? = nil, reportedAt: Date? = nil, _ change: Change,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let store = SharedStore(defaults: temporaryDefaults())
        store.hiddenPartnerStatusAt = reportedAt
        let start = start ?? base
        store.mutate { $0 = start }
        store.widgetReloadRequestedAt = nil
        store.mutate(change)
        XCTAssertNotEqual(store.snapshot, start, "the change must change something", file: file, line: line)
        return store.widgetReloadRequestedAt != nil
    }

    func testEverySnapshotFieldIsClassified() {
        let later = Fixtures.date(60)
        var other = Fixtures.moment("o1", at: later)
        other.caption = "other"
        let fields: [String: (drawn: Bool, change: Change)] = [
            "mine": (true, { $0.mine?.emoji = "🌙" }),
            "theirs": (true, { $0.theirs?.message = "home soon" }),
            "isPaired": (true, { $0.isPaired = false }),
            "lastSyncedAt": (false, { $0.lastSyncedAt = later }),
            "lastSeenPartnerNudgeCount": (false, { $0.lastSeenPartnerNudgeCount = 5 }),
            "lastNudgeSentAt": (true, { $0.lastNudgeSentAt = later }),
            "lastNudgeFailedAt": (true, { $0.lastNudgeFailedAt = later }),
            "lastNudgeIssuedAt": (true, { $0.lastNudgeIssuedAt = later }),
            "myStatusPublished": (false, { $0.myStatusPublished = false }),
            "myStatusLoggedAt": (false, { $0.myStatusLoggedAt = later }),
            "lastBreakthroughNudgeAt": (false, { $0.lastBreakthroughNudgeAt = later }),
            "latestPartnerMoment": (false, { $0.latestPartnerMoment = other }),
            "latestOwnMoment": (false, { $0.latestOwnMoment = other }),
            "lastNotifiedMomentID": (false, { $0.lastNotifiedMomentID = "o1" }),
            "notifiedMomentIDs": (false, { $0.notifiedMomentIDs = ["o1"] }),
            "owedMoments": (false, { $0.owedMoments = [other] }),
            "newsAfter": (false, { $0.newsAfter = later }),
            "latestPartnerVisualMoment": (true, { $0.latestPartnerVisualMoment = other }),
            // The marks alone: the picture they move is `latestPartnerVisualMoment`.
            "widgetHiddenMomentIDs": (false, { $0.widgetHiddenMomentIDs = ["p1"] }),
            "removalNotices": (false, { $0.removalNotices = ["p1"] }),
            "unheardVoiceMemoCount": (true, { $0.unheardVoiceMemoCount = 2 }),
            "lastCelebratedAt": (false, { $0.lastCelebratedAt = later }),
            "lastAnnouncedPartnerStatusAt": (false, { $0.lastAnnouncedPartnerStatusAt = later }),
            "lastAnnouncedPartnerStatus": (false, { $0.lastAnnouncedPartnerStatus = Fixtures.status() }),
            "receiptsDirty": (false, { $0.receiptsDirty = true }),
            "receiptsUnsettled": (false, { $0.receiptsUnsettled.toggle() }),
            "partnerStatusSeen": (false, { $0.partnerStatusSeen = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: later) }),
            "myStatusSeenByPartner": (false, { $0.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: later) }),
            "anniversary": (true, { $0.anniversary = Anniversary(startsAt: Fixtures.t0) }),
            "anniversaryPublished": (false, { $0.anniversaryPublished.toggle() }),
            "anniversaryRequestedAt": (false, { $0.anniversaryRequestedAt = later }),
            "anniversaryRequestPublished": (false, { $0.anniversaryRequestPublished.toggle() }),
            "anniversaryRequestDismissedAt": (false, { $0.anniversaryRequestDismissedAt = later }),
            "freshStart": (false, { $0.freshStart.clearedBefore = later }),
            "partnerNudgeCreatedAt": (false, { $0.partnerNudgeCreatedAt = later }),
            "partnerLeftAt": (false, { $0.partnerLeftAt = later }),
            "partnerLeftName": (false, { $0.partnerLeftName = "Sam" }),
            "partnerLeftAnnounced": (false, { $0.partnerLeftAnnounced.toggle() }),
        ]
        let labels = Set(Mirror(reflecting: Snapshot.empty).children.compactMap(\.label))
        XCTAssertEqual(Set(fields.keys), labels, "classify every stored field")
        for (field, entry) in fields.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(redraws(entry.change), entry.drawn, "\(field) \(entry.drawn ? "is" : "isn't") drawn")
        }
    }

    /// Each side draws its emoji and words; only theirs, its name. The dates and
    /// the celebration fields are drawn only through a report or a seal, below.
    func testEveryStatusFieldIsClassified() {
        let later = Fixtures.date(60)
        let fields: [String: (mine: Bool, theirs: Bool, change: (inout StatusPayload) -> Void)] = [
            "emoji": (true, true, { $0.emoji = "🌙" }),
            "message": (true, true, { $0.message = "home soon" }),
            "displayName": (false, true, { $0.displayName = "Alex" }),
            "updatedAt": (false, false, { $0.updatedAt = later }),
            "nudgeCount": (false, false, { $0.nudgeCount += 1 }),
            "lastNudgeAt": (false, false, { $0.lastNudgeAt = later }),
            "isCelebration": (false, false, { $0.isCelebration.toggle() }),
            "celebrationStyle": (false, false, { $0.celebrationStyle = .confetti }),
            "wordsSince": (false, false, { $0.wordsSince = Fixtures.date(-30) }),
            "serverSavedAt": (false, false, { $0.serverSavedAt = later }),
        ]
        let labels = Set(Mirror(reflecting: Fixtures.status()).children.compactMap(\.label))
        XCTAssertEqual(Set(fields.keys), labels, "classify every stored field")
        for (field, entry) in fields.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(redraws { if $0.mine != nil { entry.change(&$0.mine!) } }, entry.mine, "mine.\(field)")
            XCTAssertEqual(redraws { if $0.theirs != nil { entry.change(&$0.theirs!) } }, entry.theirs, "theirs.\(field)")
        }
    }

    /// The photo widget draws which picture, its kind, caption and sender; a
    /// picture marked seen or favourited changes no pixel.
    func testEveryPictureFieldIsClassified() {
        let later = Fixtures.date(60)
        let fields: [String: (drawn: Bool, change: (inout Moment) -> Void)] = [
            "id": (true, { $0 = Moment(id: "p2", kind: $0.kind, caption: $0.caption, senderName: $0.senderName,
                                       sentAt: $0.sentAt, fromMe: $0.fromMe, seen: $0.seen, uploaded: $0.uploaded) }),
            "kind": (true, { $0.kind = .drawing }),
            "caption": (true, { $0.caption = "evening" }),
            "senderName": (true, { $0.senderName = "Alex" }),
            "sentAt": (false, { $0.sentAt = later }),
            "fromMe": (false, { $0.fromMe.toggle() }),
            "seen": (false, { $0.seen.toggle() }),
            "seenAt": (false, { $0.seenAt = later }),
            "seenByPartnerAt": (false, { $0.seenByPartnerAt = later }),
            "uploaded": (false, { $0.uploaded.toggle() }),
            "captionPublished": (false, { $0.captionPublished.toggle() }),
            "captionEditedAt": (false, { $0.captionEditedAt = later }),
            "favouritedAt": (false, { $0.favouritedAt = later }),
            "duration": (false, { $0.duration = 12 }),
            "waveform": (false, { $0.waveform = [0.5] }),
        ]
        let labels = Set(Mirror(reflecting: Fixtures.moment("p1")).children.compactMap(\.label))
        XCTAssertEqual(Set(fields.keys), labels, "classify every stored field")
        for (field, entry) in fields.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(redraws { entry.change(&$0.latestPartnerVisualMoment!) }, entry.drawn, "picture.\(field)")
        }
    }

    /// The partner re-picks the words this phone reported: only the date moved,
    /// and the words show again.
    func testAReportLiftedByANewDateRedraws() {
        XCTAssertTrue(redraws(reportedAt: Fixtures.t0) { $0.theirs?.updatedAt = Fixtures.date(60) })
        XCTAssertFalse(redraws { $0.theirs?.updatedAt = Fixtures.date(60) }, "unreported, a date draws nothing")
    }

    /// A surprise draws sealed until it's opened: opening it is a redraw,
    /// though `lastCelebratedAt` alone isn't drawn.
    func testOpeningASurpriseRedraws() {
        var sealed = base
        sealed.theirs?.isCelebration = true
        sealed.theirs?.celebrationStyle = .reveal
        XCTAssertTrue(redraws(from: base) { $0 = sealed }, "sealing hides the words")
        XCTAssertTrue(redraws(from: sealed) { $0.lastCelebratedAt = Fixtures.t0 }, "opened: the words show")
    }

    /// A file isn't in the snapshot: its landing redraws only for the picture
    /// the widget shows, whichever download brought it.
    func testOnlyTheDrawnPicturesFileRedraws() {
        let store = SharedStore(defaults: temporaryDefaults())
        store.mutate { $0 = self.base }
        store.widgetReloadRequestedAt = nil

        store.mediaLanded(for: ["older", "memo"])
        XCTAssertNil(store.widgetReloadRequestedAt, "history's files draw nothing")
        store.mediaLanded(for: [])
        XCTAssertNil(store.widgetReloadRequestedAt)
        store.mediaLanded(for: ["older", "p1"])
        XCTAssertNotNil(store.widgetReloadRequestedAt, "the drawn picture sharpens")
    }

    /// The gallery's paging: the reload is owed to the caller, not spent per page.
    func testADeferredRefreshReportsTheRedrawWithoutSpendingIt() {
        let store = SharedStore(defaults: temporaryDefaults())
        let index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        index.insert([Fixtures.moment("v1", kind: .voice)])
        store.refreshDerived(index: index)
        XCTAssertEqual(store.snapshot.unheardVoiceMemoCount, 1)
        store.widgetReloadRequestedAt = nil

        index.markSeen(ids: ["v1"])
        let refreshed = store.refreshDerived(deferringWidgetReload: true, index: index)
        XCTAssertTrue(refreshed.changed, "the badge moved: a reload is owed")
        XCTAssertNil(store.widgetReloadRequestedAt, "but not spent here")
    }
}
