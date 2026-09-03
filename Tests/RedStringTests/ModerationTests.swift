import XCTest

/// The guideline 1.2 pieces: the word filter, the report mail, and the store
/// keys that make a report or block stick.
final class ModerationTests: XCTestCase {
    func testFilterMatchesWholeWordsOnly() {
        XCTAssertTrue(ContentFilter.flags("what the fuck"))
        XCTAssertTrue(ContentFilter.flags("FUCK!"))
        XCTAssertTrue(ContentFilter.flags("you absolute wanker."))
        XCTAssertFalse(ContentFilter.flags("Scunthorpe"))
        XCTAssertFalse(ContentFilter.flags("let me assist you"))
        XCTAssertFalse(ContentFilter.flags(""))
        XCTAssertFalse(ContentFilter.flags("missing you 🥰"))
    }

    func testFilterFoldsDiacritics() {
        XCTAssertTrue(ContentFilter.flags("shít happens"))
    }

    func testReportMailCarriesTheEssentials() throws {
        let pairing = PairingInfo(role: .participant, zoneName: "CoupleZone",
                                  zoneOwnerName: "_owner123", pairedAt: Fixtures.t0)
        let details = Report.Details(kind: "photo", identifier: "ABC", senderName: "Sam",
                                     text: "caption", pairing: pairing, reporterName: "Alex")
        let body = Report.body(for: details)
        XCTAssertTrue(body.contains("24 hours"))
        XCTAssertTrue(body.contains("_owner123"))
        XCTAssertTrue(body.contains("participant"))
        XCTAssertTrue(body.contains("caption"))

        let url = try XCTUnwrap(Report.mailURL(for: details))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:\(AppConfig.supportEmail)?"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "subject" }?.value,
                       "\(AppConfig.appName) report: photo")
    }

    func testStoreKeysRoundTrip() {
        let store = SharedStore(defaults: temporaryDefaults())
        XCTAssertEqual(store.acceptedTermsVersion, 0)
        XCTAssertTrue(store.contentFilterEnabled)
        XCTAssertEqual(store.hiddenMomentIDs, [])
        XCTAssertNil(store.hiddenPartnerStatusAt)
        XCTAssertEqual(store.blockedOwnerRecordNames, [])

        store.acceptedTermsVersion = 3
        store.contentFilterEnabled = false
        store.hiddenMomentIDs = ["m1"]
        store.hiddenPartnerStatusAt = Fixtures.t0
        store.blockedOwnerRecordNames = ["_owner123"]
        XCTAssertEqual(store.acceptedTermsVersion, 3)
        XCTAssertFalse(store.contentFilterEnabled)
        XCTAssertEqual(store.hiddenMomentIDs, ["m1"])
        XCTAssertEqual(store.hiddenPartnerStatusAt, Fixtures.t0)
        XCTAssertEqual(store.blockedOwnerRecordNames, ["_owner123"])
    }

    func testClearingThePairingKeepsBlocksAndReportsButNotTheStatusHide() {
        let store = SharedStore(defaults: temporaryDefaults())
        store.hiddenMomentIDs = ["m1"]
        store.hiddenPartnerStatusAt = Fixtures.t0
        store.blockedOwnerRecordNames = ["_owner123"]
        store.clearPairing(keepingName: true)
        XCTAssertEqual(store.hiddenMomentIDs, ["m1"])
        XCTAssertEqual(store.blockedOwnerRecordNames, ["_owner123"])
        XCTAssertNil(store.hiddenPartnerStatusAt, "the next partner's status must not inherit a hide")
    }
}
