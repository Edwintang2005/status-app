import CloudKit
import XCTest

/// The share's participant list as the pairing rules read it (invariants 8, 9):
/// who counts as on it, whom the close re-seats, what a block refuses.
final class SharePostureTests: XCTestCase {
    private let owner = ShareMember(role: .owner, acceptance: .accepted, userRecordName: "_owner")

    private func posture(_ others: ShareMember...) -> SharePosture {
        SharePosture([owner] + others)
    }

    func testMembersAreCountedOnceAndNeverAsLeavers() {
        XCTAssertEqual(posture().memberCount, 0, "the owner alone is nobody else")
        XCTAssertEqual(posture(.init(role: .publicUser, acceptance: .accepted, userRecordName: "_p")).memberCount, 1)
        XCTAssertEqual(posture(.init(role: .publicUser, acceptance: .removed, userRecordName: "_p")).memberCount, 0,
                       "someone who left is not on the share")
        XCTAssertEqual(posture(.init(role: .publicUser, acceptance: .accepted, userRecordName: "_p"),
                               .init(role: .privateUser, acceptance: .pending, userRecordName: "_p")).memberCount, 1,
                       "the re-seated partner listed twice is still one person")
        XCTAssertEqual(posture(.init(role: .privateUser, acceptance: .pending),
                               .init(role: .publicUser, acceptance: .accepted)).memberCount, 2,
                       "unnamed participants can't be told apart, so each counts")
        XCTAssertEqual(posture(.init(role: .publicUser, acceptance: .accepted, userRecordName: "_p"),
                               .init(role: .publicUser, acceptance: .accepted, userRecordName: "_stranger")).memberCount, 2)
    }

    func testOnlyPublicJoinersStillOnTheShareAreReseated() {
        XCTAssertTrue(ShareMember(role: .publicUser, acceptance: .accepted).isPublicJoiner)
        XCTAssertTrue(ShareMember(role: .publicUser, acceptance: .pending).isPublicJoiner)
        XCTAssertFalse(ShareMember(role: .publicUser, acceptance: .removed).isPublicJoiner)
        XCTAssertFalse(ShareMember(role: .privateUser, acceptance: .accepted).isPublicJoiner)
        XCTAssertFalse(owner.isPublicJoiner)
    }

    /// The close handshake's verification: the re-add landed as a private seat,
    /// pending counting — the partner's link tap is what accepts it.
    func testAPrivateSeatIsAnyNonOwnerNonPublicRole() {
        XCTAssertTrue(posture(.init(role: .privateUser, acceptance: .pending)).someoneSeatedPrivately)
        XCTAssertFalse(posture(.init(role: .publicUser, acceptance: .accepted)).someoneSeatedPrivately)
        XCTAssertFalse(posture().someoneSeatedPrivately, "the owner isn't a seat")
    }

    func testAcceptedAndPendingIgnoreTheOwner() {
        XCTAssertFalse(posture().someoneAccepted, "the owner's own acceptance proves nobody joined")
        XCTAssertTrue(posture(.init(role: .publicUser, acceptance: .accepted)).someoneAccepted)
        XCTAssertFalse(posture(.init(role: .privateUser, acceptance: .pending)).someoneAccepted)
        XCTAssertTrue(posture(.init(role: .privateUser, acceptance: .pending)).someonePending)
        XCTAssertFalse(posture(.init(role: .publicUser, acceptance: .removed)).someonePending)
    }

    func testABlockNamesEveryoneButTheOwnerAndRejoinChecksEveryone() {
        let share = posture(.init(role: .publicUser, acceptance: .removed, userRecordName: "_ex"),
                            .init(role: .privateUser, acceptance: .accepted))
        XCTAssertEqual(share.otherRecordNames, ["_ex"], "leavers too; the unnamed can't be recorded")
        XCTAssertTrue(share.includesAny(of: ["_ex"]))
        XCTAssertTrue(share.includesAny(of: ["_owner"]), "the owner is checked as well")
        XCTAssertFalse(share.includesAny(of: ["_someone"]))
        XCTAssertFalse(share.includesAny(of: []))
    }
}
