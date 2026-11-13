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
        XCTAssertTrue(snapshot.receiptsUnsettled, "pre-field: one launch re-send, as the old build did every launch")
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

    func testTheTakenListIsBoundedAndSticky() {
        var snapshot = Snapshot.empty
        let limit = Snapshot.owedMomentLimit
        snapshot.recordTaken((0..<(limit + 5)).map { "m\($0)" })
        XCTAssertEqual(snapshot.notifiedMomentIDs.count, limit)
        XCTAssertTrue(snapshot.hasTaken("m\(limit + 4)"))
        XCTAssertFalse(snapshot.hasTaken("m0"), "the oldest age out")

        snapshot.recordTaken(["m\(limit + 4)"])
        XCTAssertEqual(snapshot.notifiedMomentIDs.count, limit, "taking again must not duplicate")
        snapshot.owe([Fixtures.moment("m\(limit + 4)")])
        XCTAssertTrue(snapshot.owedMoments.isEmpty, "a re-fold never owes what was taken")
    }

    /// No mark yet is written as such, so it isn't re-seeded from the last sync on every read.
    func testAnUnsetNewsMarkRoundTripsAsUnset() throws {
        var snapshot = Snapshot.empty
        snapshot.lastSyncedAt = Fixtures.t0
        let data = try JSONEncoder.shared.encode(snapshot)
        XCTAssertNil(try JSONDecoder.shared.decode(Snapshot.self, from: data).newsAfter)
    }

    /// A snapshot from before the field: the last complete sync stands in for the mark.
    func testALegacySnapshotTakesItsNewsMarkFromTheLastSync() throws {
        let json = #"{"isPaired":true,"lastSyncedAt":"2025-09-01T10:00:00Z"}"#
        let snapshot = try JSONDecoder.shared.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.newsAfter, snapshot.lastSyncedAt)
        XCTAssertNotNil(snapshot.newsAfter)
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

    /// A pairing field this build can't read costs that field, never the
    /// pairing — a `nil` pairing would show the app as unlinked.
    func testPairingDecodesFieldByField() throws {
        let odd = try decode(PairingInfo.self,
                             #"{"role":"owner","zoneName":"CoupleZone","zoneOwnerName":"__defaultOwner__","pairedAt":"soon","userRecordName":7}"#)
        XCTAssertEqual(odd.role, .owner)
        XCTAssertEqual(odd.zoneName, "CoupleZone")
        XCTAssertNil(odd.userRecordName)
        XCTAssertEqual(odd.pairedAt, .distantPast)
        XCTAssertThrowsError(try decode(PairingInfo.self, #"{"role":"owner","zoneName":"CoupleZone"}"#),
                             "without the zone's owner there's no pairing to talk to")
        let original = PairingInfo(role: .participant, zoneName: "CoupleZone", zoneOwnerName: "_abc",
                                   pairedAt: Fixtures.t0, userRecordName: "_me")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PairingInfo.self, from: encoder.encode(original)), original)
    }

    /// A fresh start's bad sub-field (a malformed record copy) costs only
    /// itself: `clearedBefore` survives, or cleared history comes back.
    func testABadFreshStartFieldKeepsTheEpoch() throws {
        var freshStart = FreshStart()
        freshStart.clearedBefore = Fixtures.date(1_000)
        freshStart.dismissedAsk = Fixtures.date(900)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.shared.encode(freshStart)) as? [String: Any])
        json["theirs"] = ["stage": "not a number"]
        let decoded = try JSONDecoder.shared.decode(FreshStart.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.theirs)
        XCTAssertEqual(decoded.clearedBefore, Fixtures.date(1_000))
        XCTAssertEqual(decoded.dismissedAsk, Fixtures.date(900))
    }

    /// Two statuses in one second get two stamps; a stamp far ahead (a clock
    /// set back since) doesn't drag the next along.
    func testStatusStampsStrictlyIncrease() {
        let now = Fixtures.date(1_000)
        XCTAssertEqual(StatusPayload.nextStamp(after: nil, now: now), now)
        XCTAssertEqual(StatusPayload.nextStamp(after: Fixtures.date(500), now: now), now)
        XCTAssertEqual(StatusPayload.nextStamp(after: now, now: now.addingTimeInterval(0.4)), Fixtures.date(1_001))
        XCTAssertEqual(StatusPayload.nextStamp(after: Fixtures.date(1_001), now: now), Fixtures.date(1_002))
        XCTAssertEqual(StatusPayload.nextStamp(after: Fixtures.date(1_090), now: now), Fixtures.date(1_091),
                       "another device 90 s ahead: still after it, or its copy wins the save")
        XCTAssertEqual(StatusPayload.nextStamp(after: Fixtures.date(5_000), now: now), now, "an hour ahead: a clock change")
    }

    func testPartnerNameFallsBackWhenUnset() {
        // Not `moderatedPartnerName`: it reads `SharedStore.shared`, the real App Group.
        var snapshot = Snapshot.empty
        XCTAssertEqual(snapshot.partnerName(filterEnabled: true), "Partner")
        snapshot.theirs = Fixtures.status()
        XCTAssertEqual(snapshot.partnerName(filterEnabled: true), "Sam")
        snapshot.theirs?.displayName = "  "
        XCTAssertEqual(snapshot.partnerName(filterEnabled: true), "Partner")
        XCTAssertEqual(snapshot.partnerNameInSentence(filterEnabled: true), "your partner",
                       "never \"Send this to Partner\"")
        snapshot.theirs?.displayName = "Sam"
        XCTAssertEqual(snapshot.partnerNameInSentence(filterEnabled: true), "Sam")
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
        snapshot.lastNudgeIssuedAt = Fixtures.date(2)
        snapshot.myStatusPublished = false
        snapshot.myStatusLoggedAt = Fixtures.date(4)
        snapshot.lastBreakthroughNudgeAt = Fixtures.date(5)
        snapshot.latestPartnerMoment = moment
        snapshot.latestOwnMoment = own
        snapshot.lastNotifiedMomentID = moment.id
        snapshot.notifiedMomentIDs = [moment.id]
        snapshot.owedMoments = [moment]
        snapshot.newsAfter = Fixtures.date(6)
        snapshot.latestPartnerVisualMoment = moment
        snapshot.unheardVoiceMemoCount = 2
        snapshot.lastCelebratedAt = Fixtures.date(7)
        snapshot.lastAnnouncedPartnerStatusAt = Fixtures.date(8)
        snapshot.lastAnnouncedPartnerStatus = theirs
        snapshot.receiptsDirty = true
        snapshot.receiptsUnsettled = false
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
        snapshot.widgetHiddenMomentIDs = ["m2"]
        snapshot.removalNotices = ["gone"]
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
