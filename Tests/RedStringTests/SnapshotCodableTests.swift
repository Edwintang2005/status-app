import XCTest

/// `Snapshot` is the widget's cache and the announcement watermark store; an
/// old on-disk copy must decode under every newer build (CLAUDE.md invariant 5).
final class SnapshotCodableTests: XCTestCase {
    private let legacyTheirs = """
        {"emoji":"🥰","message":"missing you","displayName":"Sam",
         "updatedAt":"2026-09-01T10:00:00Z","nudgeCount":2}
        """
    private let legacyPhoto = """
        {"id":"m1","kind":"photo","caption":"","senderName":"Sam",
         "sentAt":"2026-09-01T09:00:00Z","fromMe":false}
        """

    func testLegacySnapshotDecodesWithFallbacks() throws {
        let snapshot = try decode(Snapshot.self, """
            {"isPaired":true,"lastSeenPartnerNudgeCount":2,
             "theirs":\(legacyTheirs),"latestPartnerMoment":\(legacyPhoto)}
            """)
        XCTAssertTrue(snapshot.isPaired)
        XCTAssertEqual(snapshot.theirs?.emoji, "🥰")
        XCTAssertEqual(snapshot.lastSeenPartnerNudgeCount, 2)
        XCTAssertTrue(snapshot.myStatusPublished, "pre-field snapshots must not republish")
        XCTAssertEqual(snapshot.notifiedMomentIDs, [])
        XCTAssertFalse(snapshot.receiptsDirty)
        XCTAssertNil(snapshot.partnerStatusSeen)
        XCTAssertNil(snapshot.anniversary)
        XCTAssertTrue(snapshot.anniversaryPublished, "pre-field snapshots must not republish")
        XCTAssertNil(snapshot.lastAnnouncedPartnerStatus)
        XCTAssertNil(snapshot.anniversaryRequestedAt)
        XCTAssertTrue(snapshot.anniversaryRequestPublished, "pre-field snapshots must not republish")
        XCTAssertEqual(snapshot.latestPartnerVisualMoment?.id, "m1",
                       "absent key: legacy snapshots treat every moment as a picture")
    }

    func testLegacyVoiceMomentIsNotPromotedToVisual() throws {
        let voice = legacyPhoto.replacingOccurrences(of: "\"photo\"", with: "\"voice\"")
        let snapshot = try decode(Snapshot.self, """
            {"isPaired":true,"latestPartnerMoment":\(voice)}
            """)
        XCTAssertNil(snapshot.latestPartnerVisualMoment)
    }

    func testExplicitNullVisualMomentStaysNil() throws {
        let snapshot = try decode(Snapshot.self, """
            {"isPaired":true,"latestPartnerMoment":\(legacyPhoto),"latestPartnerVisualMoment":null}
            """)
        XCTAssertNil(snapshot.latestPartnerVisualMoment, "explicit null means the picture was deleted")
    }

    func testEmptyObjectDecodes() throws {
        let snapshot = try decode(Snapshot.self, "{}")
        XCTAssertEqual(snapshot, .empty)
    }

    func testRoundTripKeepsANilVisualMomentNil() throws {
        var snapshot = everyFieldSet()
        snapshot.latestPartnerVisualMoment = nil

        let decoded = try JSONDecoder.shared.decode(Snapshot.self, from: JSONEncoder.shared.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.latestPartnerVisualMoment,
                     "nil visual moment must survive as an explicit null, not fall back")
    }

    /// A stored property without a coding key is silently never persisted.
    func testEveryStoredPropertyHasACodingKey() {
        let properties = Set(Mirror(reflecting: Snapshot.empty).children.compactMap(\.label))
        XCTAssertEqual(properties, Set(Snapshot.CodingKeys.allCases.map(\.stringValue)))
    }

    /// Guards the fixture below: a field it leaves at its default proves nothing.
    func testTheFixtureSetsEveryField() {
        let defaults = Mirror(reflecting: Snapshot.empty).children
        let set = Mirror(reflecting: everyFieldSet()).children
        for (empty, filled) in zip(defaults, set) {
            XCTAssertNotEqual(String(describing: empty.value), String(describing: filled.value),
                              "\(empty.label ?? "?") is left at its default")
        }
    }

    func testAnnouncedWatermarkIsBoundedAndSticky() {
        var snapshot = Snapshot.empty
        for index in 0..<12 { snapshot.recordAnnounced("m\(index)") }
        XCTAssertEqual(snapshot.notifiedMomentIDs.count, 8)
        XCTAssertEqual(snapshot.lastNotifiedMomentID, "m11")
        XCTAssertTrue(snapshot.hasAnnounced("m11"))
        XCTAssertTrue(snapshot.hasAnnounced("m4"))
        XCTAssertFalse(snapshot.hasAnnounced("m3"))

        snapshot.recordAnnounced("m11")
        XCTAssertEqual(snapshot.notifiedMomentIDs.count, 8, "re-announcing must not duplicate")
        XCTAssertEqual(snapshot.notifiedMomentIDs.first, "m11")
    }

    func testStatusReceiptCountsOnlyForCurrentStatus() {
        var snapshot = Snapshot.empty
        snapshot.mine = Fixtures.status("💼", "working", at: Fixtures.t0)
        snapshot.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.t0, seenAt: Fixtures.date(30))
        XCTAssertEqual(snapshot.myStatusSeenAt, Fixtures.date(30))

        snapshot.mine = Fixtures.status("🍜", "ramen night", at: Fixtures.date(60))
        XCTAssertNil(snapshot.myStatusSeenAt, "a new status starts unseen again")
    }

    func testPendingCelebrationPlaysOnce() {
        var snapshot = Snapshot.empty
        snapshot.theirs = Fixtures.status("🎉", "happy anniversary", at: Fixtures.t0, celebration: true)
        XCTAssertNotNil(snapshot.pendingCelebration)

        snapshot.lastCelebratedAt = Fixtures.t0
        XCTAssertNil(snapshot.pendingCelebration)

        snapshot.theirs = Fixtures.status("🎉", "again!", at: Fixtures.date(10), celebration: true)
        XCTAssertNotNil(snapshot.pendingCelebration, "a newer celebration plays again")

        snapshot.theirs = Fixtures.status("💼", "working", at: Fixtures.date(20))
        XCTAssertNil(snapshot.pendingCelebration)
    }

    func testAnniversaryRequestPendingIsOncePerAskAndMootOnceSet() {
        var snapshot = Snapshot.empty
        XCTAssertFalse(snapshot.anniversaryRequestPending)
        snapshot.anniversaryRequestedAt = Fixtures.t0
        XCTAssertTrue(snapshot.anniversaryRequestPending)
        snapshot.anniversaryRequestDismissedAt = Fixtures.t0
        XCTAssertFalse(snapshot.anniversaryRequestPending, "dismissed once per ask")
        snapshot.anniversaryRequestedAt = Fixtures.date(60)
        XCTAssertTrue(snapshot.anniversaryRequestPending, "asking again brings it back")
        snapshot.anniversary = Anniversary(startsAt: Fixtures.date(-86_400))
        XCTAssertFalse(snapshot.anniversaryRequestPending, "a set date answers every ask")
    }

    func testPartnerNameFallsBackWhenUnset() {
        var snapshot = Snapshot.empty
        XCTAssertEqual(snapshot.moderatedPartnerName, "Partner")
        snapshot.theirs = Fixtures.status()
        XCTAssertEqual(snapshot.moderatedPartnerName, "Sam")
        snapshot.theirs?.displayName = "  "
        XCTAssertEqual(snapshot.moderatedPartnerName, "Partner")
    }

    /// Upgrading: a published status was already logged (or was a rename the
    /// old build didn't log), so the first rename must not log it again; an
    /// unpublished one is still owed to the log.
    func testLoggedMarkIsSeededOnUpgrade() throws {
        let published = try decode(Snapshot.self, #"{"isPaired":true,"mine":\#(legacyTheirs)}"#)
        XCTAssertEqual(published.myStatusLoggedAt, published.mine?.wordsAt)
        let pending = try decode(Snapshot.self,
                                 #"{"isPaired":true,"myStatusPublished":false,"mine":\#(legacyTheirs)}"#)
        XCTAssertNil(pending.myStatusLoggedAt)
    }

    /// Every field, set away from its default, survives a round trip: a field
    /// left out of the hand-written encoder or decoder would reset on relaunch.
    func testEveryFieldRoundTrips() throws {
        let snapshot = everyFieldSet()
        let decoded = try JSONDecoder.shared.decode(Snapshot.self, from: JSONEncoder.shared.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.freshStart, snapshot.freshStart)
    }

    private func everyFieldSet() -> Snapshot {
        var mine = Fixtures.status("☕️", "coffee", at: Fixtures.date(100), nudges: 3)
        mine.wordsSince = Fixtures.date(50)
        mine.serverSavedAt = Fixtures.date(101)
        var theirs = Fixtures.status("🌙", "late", at: Fixtures.date(200), nudges: 7)
        theirs.serverSavedAt = Fixtures.date(201)
        let moment = Moment(kind: .photo, caption: "hi", senderName: "Sam", sentAt: Fixtures.date(300), fromMe: false)
        let own = Moment(kind: .voice, caption: "", senderName: "Alex", sentAt: Fixtures.date(310), fromMe: true)

        var snapshot = Snapshot.empty
        snapshot.mine = mine
        snapshot.theirs = theirs
        snapshot.isPaired = true
        snapshot.lastSyncedAt = Fixtures.date(1)
        snapshot.lastSeenPartnerNudgeCount = 6
        snapshot.lastNudgeSentAt = Fixtures.date(2)
        snapshot.lastNudgeFailedAt = Fixtures.date(3)
        snapshot.myStatusPublished = false
        snapshot.myStatusLoggedAt = Fixtures.date(4)
        snapshot.lastBreakthroughNudgeAt = Fixtures.date(5)
        snapshot.latestPartnerMoment = moment
        snapshot.latestOwnMoment = own
        snapshot.lastNotifiedMomentID = moment.id
        snapshot.notifiedMomentIDs = [moment.id]
        snapshot.lastAnnouncedMomentSentAt = Fixtures.date(6)
        snapshot.latestPartnerVisualMoment = moment
        snapshot.unheardVoiceMemoCount = 2
        snapshot.lastCelebratedAt = Fixtures.date(7)
        snapshot.lastAnnouncedPartnerStatusAt = Fixtures.date(8)
        snapshot.lastAnnouncedPartnerStatus = theirs
        snapshot.receiptsDirty = true
        snapshot.partnerStatusSeen = StatusSeen(statusUpdatedAt: Fixtures.date(9), seenAt: Fixtures.date(10))
        snapshot.myStatusSeenByPartner = StatusSeen(statusUpdatedAt: Fixtures.date(11), seenAt: Fixtures.date(12))
        snapshot.anniversary = Anniversary(startsAt: Fixtures.date(13), timeZoneID: "Australia/Sydney")
        snapshot.anniversaryPublished = false
        snapshot.anniversaryRequestedAt = Fixtures.date(14)
        snapshot.anniversaryRequestPublished = false
        snapshot.anniversaryRequestDismissedAt = Fixtures.date(15)
        snapshot.partnerNudgeCreatedAt = Fixtures.date(16)
        snapshot.partnerLeftAt = Fixtures.date(17)
        snapshot.partnerLeftName = "Sam"
        snapshot.partnerLeftAnnounced = true
        snapshot.freshStart.mine = FreshStartRecord(stage: .committed, epoch: Fixtures.date(18),
                                                    clearedBefore: Fixtures.date(-18))
        snapshot.freshStart.pendingIntent = .complete(Fixtures.date(18))
        snapshot.freshStart.theirs = FreshStartRecord(stage: .agreeing, epoch: Fixtures.date(18))
        snapshot.freshStart.clearedBefore = Fixtures.date(18)
        snapshot.freshStart.finishedBefore = Fixtures.date(18)
        snapshot.freshStart.dismissedAsk = Fixtures.date(19)
        return snapshot
    }
}
