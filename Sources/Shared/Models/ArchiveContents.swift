import Foundation

/// Everything the memories archive writes out. Neither source is whole alone:
/// the index stops at `momentHistoryLimit`, while the zone lacks unsent moments
/// and statuses from before the cloud log existed — so an archive meant to be
/// kept before a clear reads both.
struct ArchiveContents: Sendable {
    /// A read-only look at the whole zone (`SyncBackend.archiveZone`).
    struct Zone: Sendable {
        var moments: [Moment]
        var statuses: [StatusHistoryEntry]
        /// Records this phone couldn't decrypt, so the archive can't hold them.
        var unreadable: Int
    }

    /// Oldest first.
    var moments: [Moment]
    /// Oldest first.
    var statuses: [StatusHistoryEntry]
    var anniversary: Anniversary?
    var unreadable: Int
    /// `false` when the zone couldn't be read: this phone's copy only.
    var includesZone: Bool

    /// Nothing the zone held was left out.
    var isComplete: Bool { includesZone && unreadable == 0 }
    var isEmpty: Bool { moments.isEmpty && statuses.isEmpty }

    /// Local copies win: they keep what an unreadable re-delivery would blank
    /// (`MomentIndex.insert`'s rule). Reported moments stay out, like everywhere else.
    static func merged(zone: Zone?,
                       localMoments: [Moment],
                       localStatuses: [StatusHistoryEntry],
                       anniversary: Anniversary?,
                       hidden: Set<String>) -> ArchiveContents {
        var moments: [String: Moment] = [:]
        for moment in (zone?.moments ?? []) + localMoments where !hidden.contains(moment.id) {
            moments[moment.id] = moment
        }
        var statuses: [String: StatusHistoryEntry] = [:]
        for entry in (zone?.statuses ?? []) + localStatuses {
            statuses[entry.id] = entry
        }
        return ArchiveContents(
            moments: moments.values.sorted { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) },
            statuses: statuses.values.sorted { ($0.at, $0.id) < ($1.at, $1.id) },
            anniversary: anniversary,
            unreadable: zone?.unreadable ?? 0,
            includesZone: zone != nil
        )
    }
}
