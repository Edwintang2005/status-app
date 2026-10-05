import Foundation

/// What saving our status does against the copy already on the server
/// (invariants 16 and 23). Pure, so `CloudSync.saveStatus` only performs it.
enum StatusSavePolicy {
    enum Decision: Equatable, Sendable {
        case save
        /// The server already holds exactly this version: re-saving would only
        /// fire the partner's subscription again (a republish loop's quiet pushes).
        case alreadySaved
        /// The server holds a newer status — another device on this account
        /// set it later. Ours is dropped and the caller adopts theirs.
        case superseded
        /// The server copy is newer but its words can't be read here: it can't
        /// be adopted (no words) or overwritten (it may be the later status).
        /// The caller leaves ours unpublished for a pass that can read it.
        case unreadableNewer
    }

    /// `server` is the server copy as `CloudSync.payload(from:)` reads it.
    /// "Newer" needs the server stamp to be no later than this phone's present
    /// (plus `AppConfig.statusStampLeeway`): a stamp past it was written by a
    /// clock that ran ahead, and every status set since is the later one.
    /// `serverReadable` is `CloudSync.isReadable` on the server record: unreadable,
    /// only its plaintext `updatedAt` means anything.
    static func decide(server: StatusPayload?, serverReadable: Bool = true, payload: StatusPayload, now: Date) -> Decision {
        guard let server else { return .save }
        if !serverReadable {
            let newer = server.updatedAt > payload.updatedAt
                && server.updatedAt <= now.addingTimeInterval(AppConfig.statusStampLeeway)
            return newer ? .unreadableNewer : .save
        }
        if server.updatedAt == payload.updatedAt, server.sameWords(as: payload),
           server.displayName == payload.displayName {
            return .alreadySaved
        }
        if server.updatedAt > payload.updatedAt,
           server.updatedAt <= now.addingTimeInterval(AppConfig.statusStampLeeway) {
            return .superseded
        }
        return .save
    }
}
