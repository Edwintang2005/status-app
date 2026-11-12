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

    /// When the earliest standing claim on one of `ids` lapses: the app sends then,
    /// rather than waiting for its next pass.
    static func nextLapse(of ids: some Sequence<String>, in claims: [String: Date], now: Date = Date()) -> Date? {
        ids.filter { isClaimed($0, in: claims, now: now) }
            .compactMap { claims[$0].map { $0.addingTimeInterval(AppConfig.shareUploadHold) } }
            .min()
    }

    static func anyClaimed(in claims: [String: Date], now: Date = Date()) -> Bool {
        claims.keys.contains { isClaimed($0, in: claims, now: now) }
    }

    /// A timeout isn't the end of the upload — it runs on in the sheet while it
    /// moves — so only a real failure gives the moment back to the app at once.
    static func releasesClaim(after error: Error) -> Bool {
        !(error is CancellationError)
    }

    /// The caption field wraps, so its return key types a line break: read as
    /// Send when one break arrived with at most a word's autocorrection around it
    /// (anywhere in the text); a pasted block's breaks become spaces instead.
    static func captionEdit(from old: String, to new: String) -> (caption: String, send: Bool) {
        let breaks = { (text: String) in text.reduce(0) { $1.isNewline ? $0 + 1 : $0 } }
        let joined = String(new.filter { !$0.isNewline })
        // Around the break, at most a word's correction: the rest of the text is the old one.
        let kept = joined.commonPrefix(with: old).count
            + String(joined.reversed()).commonPrefix(with: String(old.reversed())).count
        let typedReturn = breaks(new) == breaks(old) + 1
            && abs(joined.count - old.count) <= 2
            && kept >= old.count - 3
            && !(old.isEmpty && !joined.isEmpty)
        if typedReturn { return (String(joined.prefix(AppConfig.captionMaxLength)), true) }
        return (Moment.caption(from: new), false)
    }

    /// The sheet's wait ran out with the upload still moving: renewed while the
    /// sheet is open, shortened if it has closed (`closing`).
    static func afterTimeout(_ id: String, in claims: [String: Date], left: Bool, now: Date = Date()) -> [String: Date] {
        let renewed = claiming(id, in: claims, now: now)
        return left ? closing(id, in: renewed, now: now) : renewed
    }

    /// Closing the sheet mid-send: the claim then lapses in `closedHold`, not
    /// the full hold, so the app sends it soon rather than in minutes.
    static func closing(_ id: String, in claims: [String: Date], now: Date = Date()) -> [String: Date] {
        guard claims[id] != nil else { return claims }
        var claims = claims
        claims[id] = now.addingTimeInterval(AppConfig.shareClosedHold - AppConfig.shareUploadHold).wholeSeconds
        return claims
    }

    /// `claims` with `id` added and the lapsed ones dropped.
    static func claiming(_ id: String, in claims: [String: Date], now: Date = Date()) -> [String: Date] {
        var kept = claims.filter { isClaimed($0.key, in: claims, now: now) }
        kept[id] = now.wholeSeconds
        return kept
    }
}
