import Foundation

/// When a moment's own motion plays.
enum MomentMotion {
    /// The partner's picture, still unseen when the gallery opened, develops like
    /// a print on its first look — once: `developed` holds what this gallery
    /// already played, and opening it marks it seen for every later one.
    static func develops(_ moment: Moment, developed: Set<String>) -> Bool {
        !moment.fromMe && moment.isPicture && moment.kind.isSupported && !moment.seen
            && !developed.contains(moment.id)
    }

    /// The zoom from Home's moment card into the gallery (`zoomsFrom`).
    static let homeCardZoomID = "home.momentCard"
}
