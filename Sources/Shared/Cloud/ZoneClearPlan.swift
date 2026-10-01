/// Which of one side's records a deletion pass removes. Each side deletes only
/// what it wrote (`PairRole` names them), so neither ever needs the other's keys
/// or consent to be online.
enum ZoneClearPlan {
    enum Scope {
        /// Leaving the share: everything this side ever wrote, or it sits in the
        /// ex's iCloud after we've gone.
        case unlink
        /// Clearing the history while staying linked. The fixed status and nudge
        /// records stay — the partner's phone reads a deleted status record as an
        /// unlink (`ParsedDelta.partnerErased`) — and so do the pair's date and
        /// its request, which the anniversary editor already clears on its own,
        /// and the `FreshStart` record, the lasting mark of what was cleared.
        /// `FreshStartPolicy.zonePlan` narrows this to records before the epoch.
        case freshStart
    }

    static func deletes(_ recordName: String, role: PairRole, scope: Scope) -> Bool {
        let history = role.momentID(fromRecordName: recordName) != nil
            || role.statusLogDate(fromRecordName: recordName) != nil
            || recordName == role.receiptRecordName
        switch scope {
        case .freshStart:
            return history
        case .unlink:
            return history
                || recordName == role.statusRecordName
                || recordName == role.nudgeRecordName
                || recordName == role.freshStartRecordName
                || (role == .participant && recordName == CloudSync.anniversaryRequestRecordName)
        }
    }
}
