import Foundation

/// When "the shared zone is gone" becomes a verdict (CLAUDE.md invariant 8):
/// only on a second sighting at least `AppConfig.zoneGoneConfirmation` after the
/// first — the invite-close handshake takes the partner off the share for a while.
enum ZoneGonePolicy {
    enum Decision: Equatable, Sendable {
        /// Stamp `now` as the first sighting; transient (`zoneUnreachable`).
        case firstSighting
        /// Seen before, too recently to act on; transient.
        case waiting
        /// Seen again after the window: unlink this device (`linkEnded`).
        case gone
    }

    /// A stamp ahead of this phone's clock (the clock was moved back) counts as
    /// no stamp, so it's restamped rather than holding off the verdict forever.
    static func decide(firstSeen: Date?, now: Date) -> Decision {
        guard let firstSeen, firstSeen <= now else { return .firstSighting }
        return now.timeIntervalSince(firstSeen) >= AppConfig.zoneGoneConfirmation ? .gone : .waiting
    }
}
