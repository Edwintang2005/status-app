import XCTest

/// The list of what's waiting to send.
final class PendingSendsTests: XCTestCase {
    private func mine(_ id: String, at seconds: Double, uploaded: Bool = false) -> Moment {
        var moment = Fixtures.moment(id, at: Fixtures.date(seconds), fromMe: true)
        moment.uploaded = uploaded
        return moment
    }

    func testOurUnsentMomentsNewestFirstAndWhatsUploadingCantBeStopped() {
        let history = [mine("old", at: 10), mine("new", at: 20), mine("sent", at: 30, uploaded: true),
                       Fixtures.moment("theirs", at: Fixtures.date(40))]
        let pending = PendingSends(history: history, sending: ["new"], status: nil, waiting: 1)
        XCTAssertEqual(pending.moments.map(\.id), ["new", "old"], "ours, unsent, newest first")
        XCTAssertEqual(pending.moments.map(\.sending), [true, false], "uploading now: it may land anyway")
        XCTAssertEqual(pending.others, 0)
    }

    /// The footer's count leaves out what's uploading; the rest is the status and other changes.
    func testOtherChangesAreCountedNotListed() {
        let pending = PendingSends(history: [mine("a", at: 10)], sending: [],
                                   status: Fixtures.status("☕️", "coffee"), waiting: 4)
        XCTAssertEqual(pending.status?.message, "coffee")
        XCTAssertEqual(pending.others, 2, "4 waiting: the photo, the status, and two more")
        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(PendingSends(history: [], sending: [], status: nil, waiting: 0).isEmpty)
    }
}
