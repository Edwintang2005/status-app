import CloudKit
import XCTest

/// `CloudSync`'s own sequencing over a fake iCloud (`FakeCloudDatabase`) and
/// temporary stores: what it files, when the token moves, how an unlink ends —
/// the I/O around the pure policies, where the review's cloud bugs lived.
final class CloudSyncSeamTests: XCTestCase {
    private var store: SharedStore!
    private var index: MomentIndex!
    private var stores: CloudStores!
    private var database: FakeCloudDatabase!
    private var sync: CloudSync!
    private let tokenKey = SharedStore.changeTokenKey(for: .owner)

    override func setUp() {
        super.setUp()
        store = SharedStore(defaults: temporaryDefaults())
        store.pairing = PairingInfo(role: .owner, zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: CKCurrentUserDefaultName, pairedAt: Fixtures.t0)
        index = MomentIndex(fileURL: temporaryFile("moments-index.json"), onCorrupt: {})
        let folder = temporaryFile("folder").deletingLastPathComponent()
        let stores = CloudStores(shared: store, index: index,
                                 media: MomentStore(directory: folder.appendingPathComponent("Moments")),
                                 statusLog: StatusHistoryLog(fileURL: temporaryFile("status-history.json"),
                                                             onCorrupt: {}),
                                 recaps: RecapStore(directory: folder.appendingPathComponent("Recaps")))
        self.stores = stores
        database = FakeCloudDatabase()
        sync = CloudSync(stores: stores, database: database, prefetchesMedia: false)
    }

    private func momentRecord(_ role: PairRole, _ id: String, readable: Bool = true,
                              zone: CKRecordZone.ID = Fixtures.zone) -> CKRecord {
        let record = CKRecord(recordType: CloudSync.RecordType.moment,
                              recordID: CKRecord.ID(recordName: role.momentRecordName(id: id), zoneID: zone))
        record[CloudSync.Field.momentID] = id as CKRecordValue
        record[CloudSync.Field.kind] = "photo" as CKRecordValue
        record[CloudSync.Field.sentAt] = Fixtures.date(100) as CKRecordValue
        if readable { record.encryptedValues[CloudSync.Field.senderName] = "Sam" }
        return record
    }

    private var storedToken: Data? { store.changeToken(for: tokenKey) }

    // MARK: Refresh

    /// The delta is filed, its news owed a banner, and only then the token kept.
    func testAFetchFilesItsDeltaThenKeepsItsToken() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        database.answer(.init(records: [momentRecord(.participant, "p1")], token: FakeCloudDatabase.token("t1")))

        let result = try await sync.refresh()

        XCTAssertEqual(database.fetchedSince, [FakeCloudDatabase.token("t0")], "continued from the stored token")
        XCTAssertEqual(result.newPartnerMoments.map(\.id), ["p1"])
        XCTAssertEqual(index.load().map(\.id), ["p1"])
        XCTAssertEqual(store.snapshot.owedMoments.map(\.id), ["p1"], "an incremental delta's moment is news")
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t1"))
    }

    /// An unlink landing while the fetch is out: nothing of the old space is
    /// filed, and its token isn't kept for whatever comes next.
    func testAnUnlinkMidFetchFilesNothingAndKeepsNoToken() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        database.answer(.init(records: [momentRecord(.participant, "p1")], token: FakeCloudDatabase.token("t1")))
        let store = store!
        database.duringFetch = { store.pairing = nil }

        _ = try await sync.refresh()

        XCTAssertTrue(index.load().isEmpty)
        XCTAssertTrue(self.store.snapshot.owedMoments.isEmpty)
        XCTAssertNotEqual(storedToken, FakeCloudDatabase.token("t1"))
    }

    /// An expired token starts the zone over — a resync, so its history isn't news.
    func testAnExpiredTokenStartsOverAsAResync() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        database.fail(CKError(.changeTokenExpired))
        database.answer(.init(records: [momentRecord(.participant, "old")], token: FakeCloudDatabase.token("t1")))

        let result = try await sync.refresh()

        XCTAssertEqual(database.fetchedSince, [FakeCloudDatabase.token("t0"), nil])
        XCTAssertTrue(result.fullResync)
        XCTAssertTrue(result.newPartnerMoments.isEmpty, "no complete fetch to judge news against: history")
        XCTAssertEqual(index.load().first?.seen, true, "filed seen, not counted as new")
        XCTAssertTrue(store.snapshot.owedMoments.isEmpty)
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t1"))
    }

    /// A record this pass couldn't read doesn't hold the token (invariant 2): it's
    /// owed, nothing of it is filed, and the delta behind it isn't fetched again.
    func testAnUnreadableRecordIsOwedAndTheTokenMovesOn() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let locked = momentRecord(.participant, "locked", readable: false)
        database.answer(.init(records: [locked], token: FakeCloudDatabase.token("t1")))

        let result = try await sync.refresh()

        XCTAssertEqual(result.unreadableRecordNames, [locked.recordID.recordName])
        XCTAssertTrue(index.load().isEmpty)
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t1"))
        XCTAssertEqual(store.unreadableTally.heldNames, [locked.recordID.recordName])
        XCTAssertTrue(database.fetchedByID.isEmpty, "this pass couldn't read: a retry would miss it again")
    }

    /// The next pass that reads its delta whole fetches what's owed by ID and
    /// files it like any delta — a moment that waited is still news.
    func testAnOwedRecordIsFetchedByIDOnceReadable() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let name = ParticipantMoment.name("waited")
        database.answer(.init(records: [momentRecord(.participant, "waited", readable: false)],
                              token: FakeCloudDatabase.token("t1")))
        _ = try await sync.refresh()

        database.byName[name] = .success(momentRecord(.participant, "waited"))
        database.answer(.init(token: FakeCloudDatabase.token("t2")))
        let result = try await sync.refresh()

        XCTAssertEqual(database.fetchedByID, [[name]])
        XCTAssertEqual(index.load().map(\.id), ["waited"])
        XCTAssertEqual(result.newPartnerMoments.map(\.id), ["waited"])
        XCTAssertEqual(store.snapshot.owedMoments.map(\.id), ["waited"], "owed a banner, late")
        XCTAssertTrue(store.unreadableTally.heldNames.isEmpty, "settled")
    }

    /// A sync over records with server dates (test records carry none): the
    /// creation and save times, by record name.
    private func datedSync(_ dates: [String: (created: Date, saved: Date)],
                           processLabel: String = "app") -> CloudSync {
        let metadata = RecordMetadata(createdAt: { dates[$0.recordID.recordName]?.created },
                                      savedAt: { dates[$0.recordID.recordName]?.saved },
                                      isForeign: { _ in false })
        return CloudSync(stores: stores, database: database, prefetchesMedia: false,
                         processLabel: processLabel, recordMetadata: metadata)
    }

    /// Missed in a resync, it's judged as one when finally read: re-fetched
    /// history is filed seen and owed no banner, however late it's read.
    func testARecordMissedInAResyncIsStillHistoryWhenRetried() async throws {
        store.mutate { $0.newsAfter = Fixtures.date(1_000) }
        let name = ParticipantMoment.name("old")
        let sync = datedSync([name: (Fixtures.date(500), Fixtures.date(500))])
        database.answer(.init(records: [momentRecord(.participant, "old", readable: false)],
                              token: FakeCloudDatabase.token("t1")))
        _ = try await sync.refresh()
        XCTAssertEqual(store.unreadableTally.owed.first?.resync, true)

        database.byName[name] = .success(momentRecord(.participant, "old"))
        database.answer(.init(token: FakeCloudDatabase.token("t2")))
        let result = try await sync.refresh()

        XCTAssertEqual(index.load().first?.seen, true, "history, not counted as new")
        XCTAssertTrue(result.newPartnerMoments.isEmpty)
        XCTAssertTrue(store.snapshot.owedMoments.isEmpty, "no banner for an old moment")
    }

    /// A new photo missed in a resync stays news however far the mark moves before
    /// it's read: a pass that missed something doesn't move the mark, and the owed
    /// record keeps the one in force when it was missed.
    func testANewMomentMissedInAResyncIsStillNewsWhenRetried() async throws {
        store.mutate { $0.newsAfter = Fixtures.date(1_000) }
        let photo = ParticipantMoment.name("new")
        let status = PairRole.participant.statusRecordName
        let later = PairRole.owner.momentRecordName(id: "later")
        let sync = datedSync([photo: (Fixtures.date(2_000), Fixtures.date(2_000)),
                              status: (Fixtures.date(3_000), Fixtures.date(3_000)),
                              later: (Fixtures.date(4_000), Fixtures.date(4_000))])
        database.answer(.init(records: [momentRecord(.participant, "new", readable: false),
                                        Fixtures.statusRecord(name: "Sam", at: Fixtures.date(3_000))],
                              token: FakeCloudDatabase.token("t1")))
        _ = try await sync.refresh()
        XCTAssertEqual(store.snapshot.newsAfter, Fixtures.date(1_000), "something was missed: the mark stays")

        // A later complete pass reads past it before the photo is fetched.
        database.answer(.init(records: [momentRecord(.owner, "later")], token: FakeCloudDatabase.token("t2")))
        database.byName[photo] = .success(momentRecord(.participant, "new"))
        _ = try await sync.refresh()

        XCTAssertEqual(store.snapshot.newsAfter, Fixtures.date(4_000))
        XCTAssertEqual(store.snapshot.owedMoments.map(\.id), ["new"], "still announced")
        XCTAssertEqual(index.load().first { $0.id == "new" }?.seen, false)
    }

    /// A resync batch a locked phone holds is still held — for the banners and
    /// the widget — and isn't a complete sync; a pass that keeps a token ends it.
    func testAHeldResyncBatchIsHeldUntilATokenIsKept() async throws {
        SharedStore.protectedDataAvailable = false
        defer { SharedStore.protectedDataAvailable = true }
        let locked = momentRecord(.participant, "locked", readable: false)
        database.answer(.init(records: [locked], token: FakeCloudDatabase.token("t1")))
        _ = try await sync.refresh()

        let tally = store.unreadableTally
        XCTAssertEqual(tally.heldNames, [locked.recordID.recordName])
        XCTAssertNotNil(tally.heldSince)
        XCTAssertTrue(tally.owed.isEmpty, "held, not owed: never fetched by ID")
        XCTAssertNil(store.snapshot.lastSyncedAt, "not a complete sync")

        SharedStore.protectedDataAvailable = true
        database.answer(.init(records: [momentRecord(.participant, "locked")], token: FakeCloudDatabase.token("t1")))
        _ = try await sync.refresh()
        XCTAssertTrue(store.unreadableTally.heldNames.isEmpty)
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t1"))
    }

    /// The widget is what catches up after an unlock: it retries on a pass that
    /// brings nothing new — the notification service never does.
    func testTheWidgetRetriesOnAnEmptyPassAndTheServiceNever() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let name = ParticipantMoment.name("missed")
        store.noteFetched(missed: [name], settled: [])
        database.byName[name] = .success(momentRecord(.participant, "missed"))

        _ = try await datedSync([:], processLabel: "notification service").refresh()
        XCTAssertTrue(database.fetchedByID.isEmpty)

        _ = try await datedSync([:], processLabel: "widget").refresh()
        XCTAssertEqual(database.fetchedByID, [[name]])
        XCTAssertEqual(index.load().map(\.id), ["missed"])

        // Its own misses are tallied under its own name, for Diagnostics.
        database.answer(.init(records: [momentRecord(.participant, "locked", readable: false)],
                              token: FakeCloudDatabase.token("t2")))
        _ = try await datedSync([:], processLabel: "widget").refresh()
        XCTAssertEqual(store.unreadableTally.counts["widget"], 1)
    }

    /// A retry that fetched nothing gives its claim back; one still unreadable
    /// leaves the pass not caught up.
    func testAFailedRetryGivesItsClaimBackAndAnUnreadableOneIsNotCaughtUp() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let name = ParticipantMoment.name("r")
        store.noteFetched(missed: [name], settled: [])
        database.fetchByIDError = CKError(.networkFailure)
        _ = try await sync.refresh()
        XCTAssertNil(store.unreadableTally.lastRetryAt, "given back")

        database.byName[name] = .success(momentRecord(.participant, "r", readable: false))
        let result = try await sync.refresh()
        XCTAssertEqual(database.fetchedByID.count, 2, "tried again at once")
        XCTAssertFalse(result.isWholeDelta, "a record still unreadable isn't caught up")
        XCTAssertTrue(store.unreadableTally.lastRetryReadNothing)
    }

    /// Past the room the owed list has left, even the unlocked app holds a resync
    /// batch rather than drop history — until enough spaced looks say it's for good.
    func testAResyncBeyondTheListsRoomIsHeldThenGivenUp() {
        let hold = CloudSync.ResyncHold(keysAvailable: true, room: 1, heldPasses: 0)
        XCTAssertFalse(hold.holds(fullResync: true, missed: 1))
        XCTAssertTrue(hold.holds(fullResync: true, missed: 2), "more than the room left")
        XCTAssertFalse(hold.holds(fullResync: false, missed: 2), "incremental: owed")
        XCTAssertTrue(CloudSync.ResyncHold(keysAvailable: false).holds(fullResync: true, missed: 1))
        let lookedEnough = CloudSync.ResyncHold(keysAvailable: true, room: 1,
                                                heldPasses: AppConfig.heldResyncGiveUpPasses)
        XCTAssertFalse(lookedEnough.holds(fullResync: true, missed: 2), "the app moves on, owing what fits")
    }

    /// Through `refresh`: what's already owed counts against the room, and only
    /// the partner's records are kept as held.
    func testAResyncThatWouldOverflowWhatsOwedIsHeld() async throws {
        let already = (0..<(AppConfig.owedRecordLimit - 1)).map { ParticipantMoment.name("o\($0)") }
        store.noteFetched(missed: already, settled: [])
        database.answer(.init(records: [momentRecord(.participant, "a", readable: false),
                                        momentRecord(.owner, "mine", readable: false)],
                              token: FakeCloudDatabase.token("t1")))

        _ = try await sync.refresh()

        XCTAssertNil(storedToken, "two misses, room for one: held")
        let tally = store.unreadableTally
        XCTAssertEqual(tally.held, [ParticipantMoment.name("a")], "only what the banners read")
        XCTAssertEqual(tally.heldCount, 2)
        XCTAssertEqual(tally.heldPasses, 1, "the app with its keys looked")
        XCTAssertEqual(tally.owed.count, AppConfig.owedRecordLimit - 1, "nothing dropped")
    }

    /// A held batch's looks count only when spaced, and only the app with its keys.
    func testHeldLooksCountWhenSpaced() {
        store.noteFetched(missed: [], settled: [], holding: (["h"], 1, true), now: Fixtures.t0)
        store.noteFetched(missed: [], settled: [], holding: (["h"], 1, true), now: Fixtures.t0.addingTimeInterval(5))
        store.noteFetched(missed: [], settled: [], holding: (["h"], 1, false),
                          now: Fixtures.t0.addingTimeInterval(AppConfig.owedRetrySpacing * 3))
        XCTAssertEqual(store.unreadableTally.heldPasses, 1)
        store.noteFetched(missed: [], settled: [], holding: (["h"], 1, true),
                          now: Fixtures.t0.addingTimeInterval(AppConfig.owedRetrySpacing * 4))
        XCTAssertEqual(store.unreadableTally.heldPasses, 2)
        store.noteFetched(missed: [], settled: [], tokenKept: true)
        XCTAssertEqual(store.unreadableTally.heldPasses, 0)
        XCTAssertTrue(store.unreadableTally.held.isEmpty)
    }

    /// A stalled retry keeps its claim: the pass returns on time, and the next
    /// one doesn't pay the stall again.
    func testAStalledRetryKeepsItsClaim() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let name = ParticipantMoment.name("slow")
        store.noteFetched(missed: [name], settled: [])
        database.byName[name] = .success(momentRecord(.participant, "slow"))
        database.fetchByIDDelay = .seconds(5)
        let sync = CloudSync(stores: stores, database: database, prefetchesMedia: false, owedRetryDeadline: 0.2)

        let clock = ContinuousClock()
        let took = try await clock.measure { _ = try await sync.refresh() }
        XCTAssertLessThan(took, .seconds(2), "the pass doesn't wait out the stall")
        XCTAssertNotNil(store.unreadableTally.lastRetryAt, "the claim is kept")
        XCTAssertTrue(store.unreadableTally.lastRetryReadNothing)

        _ = try await sync.refresh()
        XCTAssertEqual(database.fetchedByID.count, 1, "not paid again within the spacing")
    }

    /// One readable, one not: the read one is filed and settled, the other stays owed.
    func testAPartlyReadableRetrySettlesWhatItRead() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let good = ParticipantMoment.name("good"), bad = ParticipantMoment.name("bad")
        store.noteFetched(missed: [good, bad], settled: [])
        database.byName[good] = .success(momentRecord(.participant, "good"))
        database.byName[bad] = .success(momentRecord(.participant, "bad", readable: false))

        _ = try await sync.refresh()

        XCTAssertEqual(index.load().map(\.id), ["good"])
        XCTAssertEqual(store.unreadableTally.heldNames, [bad])
        XCTAssertFalse(store.unreadableTally.lastRetryReadNothing)
    }

    /// A resync that reads a moment still owed from an incremental miss judges it
    /// as it was missed — news — not against today's mark.
    func testAResyncReadingAnOwedMomentJudgesItAsMissed() async throws {
        store.mutate { $0.newsAfter = Fixtures.date(1_000) }
        let name = ParticipantMoment.name("waited")
        store.noteFetched(missed: [name], settled: [])
        let sync = datedSync([name: (Fixtures.date(500), Fixtures.date(500))])
        database.answer(.init(records: [momentRecord(.participant, "waited")], token: FakeCloudDatabase.token("t1")))

        let result = try await sync.refresh()

        XCTAssertEqual(result.newPartnerMoments.map(\.id), ["waited"], "missed incrementally: still news")
        XCTAssertEqual(store.snapshot.owedMoments.map(\.id), ["waited"])
        XCTAssertTrue(store.unreadableTally.heldNames.isEmpty, "and settled")
    }

    /// Resync misses in mark order, oldest first, then the rest.
    func testARetryFilesInAFixedOrder() {
        typealias Owed = SharedStore.UnreadableTally.OwedRecord
        let owed: [String: Owed] = [
            "late": Owed(name: "late", firstMissedAt: Fixtures.t0, resync: true, newsAfter: Fixtures.date(2_000)),
            "early": Owed(name: "early", firstMissedAt: Fixtures.t0, resync: true, newsAfter: Fixtures.date(1_000)),
            "none": Owed(name: "none", firstMissedAt: Fixtures.t0, resync: true, newsAfter: nil),
            "receipt": Owed(name: "receipt", firstMissedAt: Fixtures.t0),
        ]
        let groups = CloudSync.retryGroups(["receipt", "late", "none", "early"], owed: owed)
        XCTAssertEqual(groups.map(\.names), [["none"], ["early"], ["late"], ["receipt"]])
        XCTAssertEqual(groups.map(\.resync), [true, true, true, false])
    }

    /// Gone from the server, or deleted in a delta: nothing left to fetch.
    func testAnOwedRecordTheServerNoLongerHasIsSettled() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        store.noteFetched(missed: [ParticipantMoment.name("gone"), ParticipantMoment.name("deleted")], settled: [])
        database.byName[ParticipantMoment.name("gone")] = .failure(CKError(.unknownItem))
        database.answer(.init(deletedIDs: [CKRecord.ID(recordName: ParticipantMoment.name("deleted"),
                                                       zoneID: Fixtures.zone)],
                              token: FakeCloudDatabase.token("t1")))

        _ = try await sync.refresh()

        XCTAssertEqual(database.fetchedByID, [[ParticipantMoment.name("gone")]], "the deleted one settled first")
        XCTAssertTrue(store.unreadableTally.heldNames.isEmpty)
        XCTAssertTrue(index.load().isEmpty)
    }

    /// Still unreadable: still owed, and not asked for again within the spacing.
    func testAnOwedRecordIsRetriedAtMostOncePerSpacing() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        let name = ParticipantMoment.name("stuck")
        store.noteFetched(missed: [name], settled: [])
        database.byName[name] = .success(momentRecord(.participant, "stuck", readable: false))

        _ = try await sync.refresh()
        _ = try await sync.refresh()

        XCTAssertEqual(database.fetchedByID.count, 1)
        XCTAssertEqual(store.unreadableTally.heldNames, [name])
    }

    /// An extension's one batch of many keeps its cursor but isn't a complete sync.
    func testAnExtensionsBatchWithMoreComingKeepsItsCursor() async throws {
        store.setChangeToken(FakeCloudDatabase.token("t0"), for: tokenKey)
        database.answer(.init(records: [momentRecord(.participant, "p1")],
                              token: FakeCloudDatabase.token("t1"), moreComing: true))

        let result = try await datedSync([:], processLabel: "widget").refresh()

        XCTAssertEqual(database.batchLimits, [CloudSync.extensionBatchLimit], "one batch, then the app's turn")
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t1"))
        XCTAssertNil(store.snapshot.lastSyncedAt, "not synced until nothing more is coming")
    }

    /// The app takes the zone in batches, each filed and its token kept before
    /// the next; the whole is one resync, so none of it is news.
    func testTheAppSweepsTheZoneInBatches() async throws {
        database.answer(.init(records: [momentRecord(.participant, "p1")],
                              token: FakeCloudDatabase.token("t1"), moreComing: true))
        database.answer(.init(records: [momentRecord(.participant, "p2")], token: FakeCloudDatabase.token("t2")))

        let result = try await sync.refresh()

        XCTAssertEqual(database.fetchedSince, [nil, FakeCloudDatabase.token("t1")])
        XCTAssertEqual(database.batchLimits, [CloudSync.appBatchLimit, CloudSync.appBatchLimit])
        XCTAssertEqual(Set(index.load().map(\.id)), ["p1", "p2"])
        XCTAssertTrue(result.fullResync)
        XCTAssertFalse(result.incomplete)
        XCTAssertTrue(result.newPartnerMoments.isEmpty, "history, not news")
        XCTAssertTrue(store.snapshot.owedMoments.isEmpty)
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t2"))
        XCTAssertNotNil(store.snapshot.lastSyncedAt)
        XCTAssertEqual(store.historyCoverage, AppConfig.momentHistoryLimit, "swept whole")
    }

    /// The mark a complete sweep leaves is the newest any batch read, though its
    /// last page held nothing.
    func testASweepMarksNewsAfterFromEveryBatch() async throws {
        let sync = datedSync([ParticipantMoment.name("p1"): (Fixtures.date(2_000), Fixtures.date(2_000))])
        database.answer(.init(records: [momentRecord(.participant, "p1")],
                              token: FakeCloudDatabase.token("t1"), moreComing: true))
        database.answer(.init(token: FakeCloudDatabase.token("t2")))

        _ = try await sync.refresh()

        XCTAssertEqual(store.snapshot.newsAfter, Fixtures.date(2_000))
    }

    /// Only a whole sweep says what's missing from the zone, and it adds up every
    /// batch: a send returned by an earlier batch isn't re-queued.
    func testASweepRequeuesOnlySendsNoBatchReturned() async throws {
        index.insert([Fixtures.moment("early", fromMe: true, uploaded: true),
                      Fixtures.moment("lost", fromMe: true, uploaded: true)])
        for id in ["early", "lost"] { try stores.media.write(full: Data([1]), thumb: Data([1]), id: id) }
        database.answer(.init(records: [momentRecord(.owner, "early")],
                              token: FakeCloudDatabase.token("t1"), moreComing: true))
        database.answer(.init(records: [momentRecord(.participant, "p2")], token: FakeCloudDatabase.token("t2")))

        _ = try await sync.refresh()

        let byID = Dictionary(uniqueKeysWithValues: index.load().map { ($0.id, $0) })
        XCTAssertEqual(byID["early"]?.uploaded, true, "returned by the first batch")
        XCTAssertEqual(byID["lost"]?.uploaded, false, "returned by none: sent again")
    }

    /// A sweep cut off mid-way keeps what it filed, and the next pass carries on
    /// from there — still a resync, so the rest of the history isn't news either.
    func testACutOffSweepKeepsItsProgressAndResumesAsAResync() async throws {
        database.answer(.init(records: [momentRecord(.participant, "p1")],
                              token: FakeCloudDatabase.token("t1"), moreComing: true))
        database.fail(CKError(.networkFailure))

        do {
            _ = try await sync.refresh()
            XCTFail("the second batch failed")
        } catch {}

        XCTAssertEqual(index.load().map(\.id), ["p1"])
        XCTAssertEqual(storedToken, FakeCloudDatabase.token("t1"), "the first batch's progress is kept")
        XCTAssertEqual(store.historyCoverage, HistoryCoverage.owed)
        XCTAssertNil(store.snapshot.lastSyncedAt)

        database.answer(.init(records: [momentRecord(.participant, "p2")], token: FakeCloudDatabase.token("t2")))
        let result = try await sync.refresh()

        XCTAssertEqual(database.fetchedSince.last, FakeCloudDatabase.token("t1"))
        XCTAssertTrue(result.fullResync)
        XCTAssertTrue(result.newPartnerMoments.isEmpty)
        XCTAssertEqual(index.load().first { $0.id == "p2" }?.seen, true)
        XCTAssertTrue(store.snapshot.owedMoments.isEmpty)
        XCTAssertEqual(store.historyCoverage, AppConfig.momentHistoryLimit)
    }

    // MARK: Unlink

    /// Joining another space wipes this one's history — the stores `CloudSync`
    /// was given, never the real App Group's.
    @MainActor
    func testAdoptingAnotherSpaceWipesTheInjectedStores() {
        index.insert([Fixtures.moment("p1")])
        CloudSync.adoptPairing(PairingInfo(role: .participant, zoneName: AppConfig.coupleZoneName,
                                           zoneOwnerName: "_someone-else", pairedAt: Fixtures.t0),
                               in: stores)
        XCTAssertTrue(index.load().isEmpty)
    }

    /// The owner's unlink deletes the zone, and only the zone's own result says it did.
    func testTheOwnersUnlinkIsConfirmedByTheZonesResult() async throws {
        try await sync.unpair()
        XCTAssertEqual(database.deletedZones, [Fixtures.zone])

        database.zoneDeleteResult = { _ in .failure(CKError(.networkFailure)) }
        do {
            try await sync.unpair()
            XCTFail("a zone that failed to delete isn't unlinked")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        database.zoneDeleteResult = { _ in nil }
        do {
            try await sync.unpair()
            XCTFail("a zone the server didn't report on isn't unlinked")
        } catch SyncError.saveUnconfirmed {}

        database.zoneDeleteResult = { _ in .failure(CKError(.zoneNotFound)) }
        try await sync.unpair()
    }

    /// The participant deletes their own records first — never the partner's —
    /// then leaves; with no share reference, by dropping the zone from their side.
    func testTheParticipantDeletesOnlyTheirOwnRecordsThenLeaves() async throws {
        let zone = CKRecordZone.ID(zoneName: AppConfig.coupleZoneName, ownerName: "_owner")
        store.pairing = PairingInfo(role: .participant, zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: "_owner", pairedAt: Fixtures.t0)
        let mine = momentRecord(.participant, "mine", zone: zone)
        let theirs = momentRecord(.owner, "theirs", zone: zone)
        database.answer(.init(records: [mine, theirs], token: FakeCloudDatabase.token("t1")))
        database.zones = [zone: .success(CKRecordZone(zoneID: zone))]

        try await sync.unpair()

        XCTAssertEqual(database.deletedRecords, [mine.recordID])
        XCTAssertEqual(database.deletedZones, [zone])
    }
}

/// The partner's moment record names, as the owner sees them.
private enum ParticipantMoment {
    static func name(_ id: String) -> String { PairRole.participant.momentRecordName(id: id) }
}
