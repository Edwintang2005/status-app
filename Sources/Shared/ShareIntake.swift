import Foundation

/// The share sheet's rules (`Sources/Share`): whether a shared photo can go,
/// and how long the app leaves one the sheet is sending alone.
enum ShareIntake {
    enum Blocked: Equatable, Sendable {
        case terms, unlinked, partnerLeft
    }

    /// The app gates everything on the terms; the sheet can't show them, so it sends there.
    static func blocked(termsAccepted: Bool, paired: Bool, partnerLeft: Bool) -> Blocked? {
        if !termsAccepted { return .terms }
        if !paired { return .unlinked }
        if partnerLeft { return .partnerLeft }
        return nil
    }

    /// Whether the sheet's claim on `id` still stands: the app's retry pass
    /// mustn't send it a second time alongside. The sheet waits at most
    /// `uploadDeadline`; past the hold it's gone, and a re-send only overwrites
    /// the same record. A claim from the future (a clock moved back) is stale.
    static func isClaimed(_ id: String, in claims: [String: Date], now: Date = Date()) -> Bool {
        guard let at = claims[id] else { return false }
        let age = now.timeIntervalSince(at)
        return age >= -60 && age < AppConfig.shareUploadHold
    }

    static func anyClaimed(in claims: [String: Date], now: Date = Date()) -> Bool {
        claims.keys.contains { isClaimed($0, in: claims, now: now) }
    }

    /// A timeout isn't the end of the upload — it runs on in the sheet while it
    /// moves — so only a real failure gives the moment back to the app at once.
    static func releasesClaim(after error: Error) -> Bool {
        !(error is CancellationError)
    }

    /// `claims` with `id` added and the lapsed ones dropped.
    static func claiming(_ id: String, in claims: [String: Date], now: Date = Date()) -> [String: Date] {
        var kept = claims.filter { isClaimed($0.key, in: claims, now: now) }
        kept[id] = now.wholeSeconds
        return kept
    }
}
