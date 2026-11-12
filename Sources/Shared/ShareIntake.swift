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

/// One opening of the share sheet, for Diagnostics: when its process started,
/// when it was on screen, and how it ended. A launch that never reached the
/// screen is the trace of a sheet that flashed and closed — iOS logs nothing
/// for an extension the host gave up on.
struct ShareLaunch: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case sent, queued, cancelled, unreadable, unsaved, blocked
    }

    var id: String
    /// The process's own start, when the system says; else when the sheet loaded.
    /// Whole seconds once stored, so the timings below are kept as durations.
    var processStartedAt: Date
    /// Seconds from the process's start to the sheet loading, and to its being on screen.
    var loadedAfter: TimeInterval
    var shownAfter: TimeInterval?
    var outcome: Outcome?

    static let limit = 10

    init(id: String = UUID().uuidString, processStartedAt: Date, loadedAt: Date) {
        self.id = id
        self.processStartedAt = processStartedAt
        loadedAfter = max(loadedAt.timeIntervalSince(processStartedAt), 0)
    }

    mutating func shown(at date: Date) {
        shownAfter = max(date.timeIntervalSince(processStartedAt), 0)
    }

    /// Hand-written like every stored type: a field a later build adds can't cost the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        processStartedAt = try c.decode(Date.self, forKey: .processStartedAt)
        loadedAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .loadedAfter) ?? 0
        shownAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .shownAfter)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome).flatMap(Outcome.init(rawValue:))
    }

    /// `launches` with `launch` filed (replacing its earlier copy), newest first, capped.
    static func recording(_ launch: ShareLaunch, in launches: [ShareLaunch]) -> [ShareLaunch] {
        Array(([launch] + launches.filter { $0.id != launch.id })
            .sorted { $0.processStartedAt + $0.loadedAfter > $1.processStartedAt + $1.loadedAfter }
            .prefix(limit))
    }

    var summary: String {
        let when = processStartedAt.formatted(date: .abbreviated, time: .standard)
        guard let shownAfter else {
            return "\(when) · never on screen (loaded \(Self.seconds(loadedAfter)) in)"
        }
        let words: String
        switch outcome {
        case .sent: words = "sent"
        case .queued: words = "saved, left for the app"
        case .cancelled: words = "cancelled"
        case .unreadable: words = "couldn't open the picture"
        case .unsaved: words = "couldn't save the picture"
        case .blocked: words = "not set up to send"
        case nil: words = "closed without an outcome"
        }
        return "\(when) · on screen in \(Self.seconds(shownAfter)) · \(words)"
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        "\(max(interval, 0).formatted(.number.precision(.fractionLength(1)))) s"
    }
}
