import Foundation

extension AnnouncementPolicy {
    /// The index entries `claimMomentBanner` could still fall back to, judged
    /// against a floor read before its `mutate`. The floor only rises, and the
    /// claim reads one stuck in the future as `now`, so past `min(floor, now)`
    /// keeps everything the claim's own filter would.
    static func bannerCandidates(_ index: [Moment], floor: Date?, now: Date = Date()) -> [Moment] {
        let floor = min(floor ?? .distantPast, now)
        return index.filter { !$0.fromMe && $0.sentAt > floor }
    }
}
