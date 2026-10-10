import CloudKit
import XCTest

/// Celebration styles: what travels on the record and how older or newer
/// copies read, the seasonal presets, and the surprise kept off every surface
/// until it's scratched open.
final class CelebrationTests: XCTestCase {
    private func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func seasonal(_ month: Int, _ dayOfMonth: Int) -> [String] {
        SeasonalMoods.moods(on: day(month, dayOfMonth), timeZone: TimeZone(identifier: "UTC")!).map(\.label)
    }

    // MARK: Styles

    func testAStyleOnlyCountsOnACelebration() {
        var payload = Fixtures.status()
        payload.celebrationStyle = .birthday
        XCTAssertNil(payload.celebration, "an ordinary status with a stray style plays nothing")
        payload.isCelebration = true
        XCTAssertEqual(payload.celebration, .birthday)
        payload.celebrationStyle = nil
        XCTAssertEqual(payload.celebration, .confetti, "a celebration from before styles is confetti")
    }

    func testTheRecordCarriesTheStyleAndAnUnknownOneIsConfetti() {
        let record = Fixtures.statusRecord(name: "Sam", at: Fixtures.t0)
        record.encryptedValues[CloudSync.Field.isCelebration] = 1
        record.encryptedValues[CloudSync.Field.celebrationStyle] = "trophy"
        XCTAssertEqual(CloudSync.payload(from: record, nudge: nil, existing: nil)?.celebration, .trophy)

        record.encryptedValues[CloudSync.Field.celebrationStyle] = "lanterns"
        XCTAssertEqual(CloudSync.payload(from: record, nudge: nil, existing: nil)?.celebration, .confetti,
                       "a newer build's style still plays something")
    }

    func testANewStyleIsANewStatusNotARename() {
        var trophy = Fixtures.status("🏆", "you did it!", celebration: true)
        trophy.celebrationStyle = .trophy
        var confetti = trophy
        confetti.celebrationStyle = .confetti
        XCTAssertFalse(trophy.sameWords(as: confetti))
        var legacy = trophy
        legacy.celebrationStyle = nil
        XCTAssertTrue(confetti.sameWords(as: legacy), "absent and confetti are the same celebration")
    }

    func testStoredStyleSurvivesAndAStrangeOneCostsOnlyItself() throws {
        var payload = Fixtures.status(celebration: true)
        payload.celebrationStyle = .snow
        let data = try JSONEncoder.shared.encode(payload)
        XCTAssertEqual(try JSONDecoder.shared.decode(StatusPayload.self, from: data).celebration, .snow)

        let newer = #"{"emoji":"🏮","message":"hi","isCelebration":true,"celebrationStyle":"lanterns","updatedAt":"2025-09-01T10:00:00Z"}"#
        let decoded = try decode(StatusPayload.self, newer)
        XCTAssertEqual(decoded.message, "hi")
        XCTAssertEqual(decoded.celebration, .confetti)
    }

    // MARK: Seasons

    func testHolidaysAppearOnlyAroundTheirDays() {
        XCTAssertEqual(seasonal(7, 14), [])
        XCTAssertEqual(seasonal(12, 1), ["merry christmas"])
        XCTAssertEqual(seasonal(12, 26), ["merry christmas", "happy new year"], "Boxing Day overlaps")
        XCTAssertEqual(seasonal(12, 31), ["happy new year"])
        XCTAssertEqual(seasonal(1, 7), ["happy new year"], "the window wraps the new year")
        XCTAssertEqual(seasonal(1, 8), [])
        XCTAssertEqual(seasonal(2, 14), ["happy valentine's day"])
        XCTAssertEqual(seasonal(2, 16), [])
    }

    func testUsOpensWithTheSeason() {
        let us = MoodGroup.us.moods(on: day(12, 20))
        XCTAssertEqual(us.first?.celebration, .snow)
        XCTAssertEqual(MoodGroup.mood.moods(on: day(12, 20)), MoodGroup.mood.moods, "only Us carries the season")
    }

    // MARK: The sealed surprise

    private func surprise(played: Bool) -> Snapshot {
        var snapshot = Snapshot.empty
        var payload = Fixtures.status("💍", "we're engaged!", at: Fixtures.date(100), celebration: true)
        payload.celebrationStyle = .reveal
        snapshot.theirs = payload
        if played { snapshot.lastCelebratedAt = Fixtures.date(100) }
        return snapshot
    }

    func testASurpriseIsSealedUntilItsPlayed() {
        XCTAssertTrue(surprise(played: false).partnerStatusSealed)
        XCTAssertEqual(surprise(played: false).sealedPartnerWordsAt, Fixtures.date(100))
        XCTAssertFalse(surprise(played: true).partnerStatusSealed)

        var trophy = surprise(played: false)
        trophy.theirs?.celebrationStyle = .trophy
        XCTAssertFalse(trophy.partnerStatusSealed, "only the reveal is a secret")
    }

    func testSealedWordsStayOffEverySurface() throws {
        let snapshot = surprise(played: false)
        let status = try XCTUnwrap(snapshot.theirs)
        let shown = status.moderation(reportedAt: nil, sealed: true, filterEnabled: false)
        XCTAssertEqual(shown, .sealed)
        XCTAssertFalse(shown.message.text.contains("engaged"))
        XCTAssertNotEqual(shown.emoji, "💍", "the emoji could give it away too")
        XCTAssertFalse(status.wordsShown(reportedAt: nil, revealed: false, sealed: true, filterEnabled: false),
                       "no read receipt for words nobody has seen")

        let widget = WidgetContent(snapshot: snapshot, reportedAt: nil, filterEnabled: false)
        XCTAssertFalse(widget.partner?.message.contains("engaged") ?? true)

        let banner = PushBannerPolicy.statusBody(status, reportedAt: nil, sealed: true)
        XCTAssertFalse(banner.contains("engaged"))
        XCTAssertFalse(banner.contains("💍"))

        let entry = StatusHistoryEntry(status, fromMe: false)
        XCTAssertEqual(entry.moderation(reportedAt: nil, sealedAt: snapshot.sealedPartnerWordsAt,
                                        filterEnabled: false), .sealed)
        XCTAssertEqual(entry.moderation(reportedAt: nil, sealedAt: nil, filterEnabled: false).message.text,
                       "we're engaged!", "opened, it's an ordinary entry")
    }

    func testAReportedSurpriseStaysReported() throws {
        let status = try XCTUnwrap(surprise(played: false).theirs)
        XCTAssertEqual(status.moderation(reportedAt: Fixtures.date(100), sealed: true, filterEnabled: false), .reported)
    }
}
