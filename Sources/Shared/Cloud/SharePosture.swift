import CloudKit

/// One person on the share, reduced to the facts the pairing rules judge, so
/// they're tested without building a `CKShare`.
struct ShareMember: Equatable, Sendable {
    var role: CKShare.ParticipantRole
    var acceptance: CKShare.ParticipantAcceptanceStatus
    var userRecordName: String?

    init(role: CKShare.ParticipantRole,
         acceptance: CKShare.ParticipantAcceptanceStatus,
         userRecordName: String? = nil) {
        self.role = role
        self.acceptance = acceptance
        self.userRecordName = userRecordName
    }

    init(_ participant: CKShare.Participant) {
        self.init(role: participant.role,
                  acceptance: participant.acceptanceStatus,
                  userRecordName: participant.userIdentity.userRecordID?.recordName)
    }

    var isOwner: Bool { role == .owner }
    /// Still on the share besides the owner: a leaver (`removed`) isn't.
    var isMember: Bool { !isOwner && acceptance != .removed }
    /// Came in through the link and hasn't left — whom the close re-seats.
    var isPublicJoiner: Bool { role == .publicUser && acceptance != .removed }
    /// Seated privately, invited or accepted: the close handshake's re-add.
    var isPrivatelySeated: Bool { !isOwner && role != .publicUser }
}

/// What the share's participant list says, judged as a whole (invariants 8, 9).
struct SharePosture: Equatable, Sendable {
    var members: [ShareMember]

    init(_ members: [ShareMember]) {
        self.members = members
    }

    init(_ share: CKShare) {
        self.init(share.participants.map(ShareMember.init))
    }

    /// People besides the owner, each counted once, leavers not at all — every
    /// "is someone else here" judgement goes through this.
    var memberCount: Int {
        let others = members.filter(\.isMember)
        let named = Set(others.compactMap(\.userRecordName))
        return named.count + others.filter { $0.userRecordName == nil }.count
    }

    var someoneAccepted: Bool { members.contains { !$0.isOwner && $0.acceptance == .accepted } }
    var someonePending: Bool { members.contains { !$0.isOwner && $0.acceptance == .pending } }
    var someoneSeatedPrivately: Bool { members.contains(where: \.isPrivatelySeated) }

    /// Everyone but the owner who can be named, leavers included: whom a block refuses.
    var otherRecordNames: [String] {
        members.filter { !$0.isOwner }.compactMap(\.userRecordName)
    }

    /// Anyone on it, the owner included, is in `blocked`.
    func includesAny(of blocked: Set<String>) -> Bool {
        members.contains { $0.userRecordName.map(blocked.contains) ?? false }
    }
}
