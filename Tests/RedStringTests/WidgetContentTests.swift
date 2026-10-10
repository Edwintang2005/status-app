import XCTest

/// What the widgets draw, moderated once per entry (invariant 20), and how large
/// the photo widget decodes its picture.
final class WidgetContentTests: XCTestCase {
    private func snapshot(_ theirs: StatusPayload?) -> Snapshot {
        var snapshot = Snapshot.empty
        snapshot.isPaired = true
        snapshot.theirs = theirs
        return snapshot
    }

    func testAReportedStatusShowsNoWords() {
        let theirs = Fixtures.status("🥰", "missing you", at: Fixtures.t0)
        let content = WidgetContent(snapshot: snapshot(theirs), reportedAt: Fixtures.t0, filterEnabled: true)
        XCTAssertEqual(content.partner?.emoji, "💭")
        XCTAssertEqual(content.partner?.message, ContentFilter.reportedPlaceholder)
    }

    func testAFilteredMessageAndNameAreHiddenOnlyWithTheFilterOn() {
        var theirs = Fixtures.status("😤", "this is bullshit")
        theirs.displayName = "shit"
        let on = WidgetContent(snapshot: snapshot(theirs), reportedAt: nil, filterEnabled: true)
        XCTAssertEqual(on.partner?.message, String(localized: "Hidden"), "a stand-in that fits a tile")
        XCTAssertNil(on.partnerName, "a hidden name reads as no name, not as a heading")

        let off = WidgetContent(snapshot: snapshot(theirs), reportedAt: nil, filterEnabled: false)
        XCTAssertEqual(off.partner?.message, "this is bullshit")
        XCTAssertEqual(off.partnerName, "shit")
    }

    func testANameIsKnownOnlyOnceTheyPublishedOne() {
        var theirs = Fixtures.status()
        theirs.displayName = "  "
        XCTAssertNil(WidgetContent(snapshot: snapshot(theirs), reportedAt: nil, filterEnabled: true).partnerName)
        XCTAssertNil(WidgetContent(snapshot: snapshot(nil), reportedAt: nil, filterEnabled: true).partnerName)
        theirs.displayName = "Sam"
        XCTAssertEqual(WidgetContent(snapshot: snapshot(theirs), reportedAt: nil, filterEnabled: true).partnerName,
                       "Sam")
    }

    func testThePhotoCarriesItsCaptionAndTheCounts() {
        var snapshot = snapshot(nil)
        var photo = Fixtures.moment("p1")
        photo.caption = "morning"
        snapshot.latestPartnerVisualMoment = photo
        snapshot.unheardVoiceMemoCount = 2
        snapshot.lastNudgeSentAt = Fixtures.date(5)
        let content = WidgetContent(snapshot: snapshot, reportedAt: nil, filterEnabled: true)
        XCTAssertEqual(content.photo?.id, "p1")
        XCTAssertEqual(content.photo?.caption, "morning")
        XCTAssertEqual(content.unheardMemos, 2)
        XCTAssertEqual(content.lastNudgeSentAt, Fixtures.date(5))
    }

    func testTheGallerySampleIsFixed() {
        XCTAssertEqual(WidgetContent.preview.partner, Snapshot.preview.theirs)
        XCTAssertEqual(WidgetContent.preview.partnerName, "Sam")
        XCTAssertNil(WidgetContent.previewWaiting.partner)
        XCTAssertTrue(WidgetContent.previewWaiting.isPaired)
    }

    // MARK: Photo size

    func testThePhotoDecodesToFillTheTile() {
        // A 4:3 landscape full copy on a large tile (~364×382 pt at 3×): the height fills.
        let large = CGSize(width: 1092, height: 1146)
        let landscape = WidgetPhotoSize.maxPixel(image: CGSize(width: 2048, height: 1536), filling: large)
        XCTAssertEqual(landscape, (2048 * 1146 / 1536.0).rounded(.up))

        // Portrait on a medium tile: the width fills.
        let medium = CGSize(width: 1092, height: 507)
        XCTAssertEqual(WidgetPhotoSize.maxPixel(image: CGSize(width: 1536, height: 2048), filling: medium),
                       (2048 * 1092 / 1536.0).rounded(.up))
    }

    func testThePhotoIsNeverUpscaledOrDecodedPastTheCrop() {
        let tile = CGSize(width: 1092, height: 1146)
        XCTAssertEqual(WidgetPhotoSize.maxPixel(image: CGSize(width: 640, height: 480), filling: tile), 640,
                       "a small file decodes as it is")
        XCTAssertEqual(WidgetPhotoSize.maxPixel(image: CGSize(width: 40_000, height: 100), filling: tile), 2 * 1146,
                       "a panorama the crop mostly drops can't decode past the ceiling")
        XCTAssertNil(WidgetPhotoSize.maxPixel(image: .zero, filling: tile))
    }
}
