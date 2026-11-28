import Foundation

extension StatusPayload {
    /// A new status of this phone's, as every way of setting one builds it — the
    /// picker, a banner reply, Siri, the widget: words trimmed and capped (only
    /// the picker's field caps as you type), the name kept, stamped after the last.
    static func composed(emoji: String, message: String, celebration: CelebrationStyle? = nil,
                         after mine: StatusPayload?, now: Date = Date()) -> StatusPayload {
        StatusPayload(emoji: emoji,
                      message: String(message.trimmingCharacters(in: .whitespacesAndNewlines)
                                          .prefix(AppConfig.statusMessageMaxLength)),
                      displayName: mine?.displayName ?? "",
                      updatedAt: nextStamp(after: mine?.updatedAt, now: now),
                      nudgeCount: mine?.nudgeCount ?? 0,
                      lastNudgeAt: mine?.lastNudgeAt,
                      isCelebration: celebration != nil,
                      celebrationStyle: celebration)
    }
}

extension Snapshot {
    /// Shows `payload` as this phone's status at once, owed until it lands — in
    /// one write, so a crash between can't strand a status that looks delivered.
    /// The heart's fields are the store's: the lock-screen heart may have moved them.
    mutating func adoptOwnStatus(_ payload: StatusPayload, paired: Bool) {
        var current = payload
        current.nudgeCount = mine?.nudgeCount ?? payload.nudgeCount
        current.lastNudgeAt = mine?.lastNudgeAt ?? payload.lastNudgeAt
        mine = current
        myStatusPublished = !paired
    }

    /// This phone's status if its publish never landed, or only its `StatusLog`
    /// record didn't — then `logged` is what's sent (the status save finds its
    /// own copy there and skips). Not logged twice: a retried rename must not
    /// log its old words as a new status.
    var owedStatus: (status: StatusPayload, logged: Bool)? {
        guard let mine else { return nil }
        let logged = myStatusLoggedAt != mine.wordsAt
        guard !myStatusPublished || (logged && mine.updatedAt > .distantPast) else { return nil }
        return (mine, logged)
    }
}

/// A status set from outside the app — Siri, Shortcuts, the quick-status
/// widget. Shown and logged at once; sent within the intent's time, or left
/// owed (`myStatusPublished` down) for the app's outbox, or the widget's next
/// refresh, to send (invariant 11).
enum QuickStatus {
    /// - Returns: `nil` once it reached iCloud (or there's no one to send it to); why not, otherwise.
    @MainActor
    static func set(emoji: String, message: String,
                    store: SharedStore = .shared,
                    statusLog: StatusHistoryLog = .shared,
                    backend: () -> any SyncBackend = { Backend.current }) async -> (any Error)? {
        let paired = store.pairing != nil
        let payload = StatusPayload.composed(emoji: emoji, message: message, after: store.snapshot.mine)
        store.mutate { $0.adoptOwnStatus(payload, paired: paired) }
        statusLog.record(payload, fromMe: true)
        // In the app (Siri) the model holds its own copy: a re-read, not a fetch.
        NotificationCenter.default.post(name: .snapshotDidChange, object: nil)
        guard paired else { return nil }
        let backend = backend()
        do {
            // Bounded: the widget extension is suspended soon after `perform()`.
            try await withDeadline(AppConfig.widgetDeadline) { try await backend.publish(payload) }
        } catch {
            return error
        }
        NotificationCenter.default.post(name: .snapshotDidChange, object: nil)
        return nil
    }

    /// Sends an owed status (`Snapshot.owedStatus`) and marks it, against the
    /// then-current status (invariant 16): the outbox's step, and the widget's.
    @MainActor
    static func resend(_ owed: (status: StatusPayload, logged: Bool), store: SharedStore,
                       backend: any SyncBackend, deadline: TimeInterval) async throws {
        let (mine, logged) = owed
        try await withDeadline(deadline) { try await backend.publish(mine, logged: logged) }
        store.mutate {
            $0.markStatusPublished(mine)
            // A logged publish that returned wrote the log; with a null mark
            // meaning "owed", nothing else may be left to claim it landed.
            if logged { $0.recordLogged(mine) }
        }
    }

    /// The widget's refresh is often the first time online after a send from
    /// Siri or its button missed, and the app may not run for days.
    /// - Returns: whether something owed was sent.
    @MainActor @discardableResult
    static func sendOwed(store: SharedStore = .shared,
                         backend: () -> any SyncBackend = { Backend.current },
                         deadline: TimeInterval = AppConfig.owedStatusWidgetDeadline) async -> Bool {
        guard store.pairing != nil, let owed = store.snapshot.owedStatus else { return false }
        do {
            try await resend(owed, store: store, backend: backend(), deadline: deadline)
            return true
        } catch {
            return false
        }
    }
}

/// What Siri heard, as one status — never a list to tap through: the same
/// words, else the closest of yours that holds them (or that they hold), else
/// the words themselves, as a status of their own.
enum SpokenStatus {
    typealias Choice = (emoji: String, message: String)

    /// `options` most recent first: a tie goes to the one you used last.
    static func match(_ spoken: String, among options: [Choice]) -> Choice? {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let emoji = options.first(where: { $0.emoji == trimmed }) { return emoji }
        let said = normalised(spoken)
        guard !said.isEmpty else { return nil }
        if let exact = options.first(where: { normalised($0.message) == said }) { return exact }
        let near = options.filter {
            let words = normalised($0.message)
            return !words.isEmpty && (words.contains(said) || said.contains(words))
        }
        if let closest = near.min(by: { distance($0, said) < distance($1, said) }) { return closest }
        let words = trimmed.trimmingCharacters(in: .punctuationCharacters).prefix(AppConfig.statusMessageMaxLength)
        guard let first = words.first else { return nil }
        return ("💬", first.uppercased() + words.dropFirst())
    }

    /// Case, accents and punctuation aside: dictation adds a full stop, Siri a capital.
    static func normalised(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func distance(_ choice: Choice, _ said: String) -> Int {
        abs(normalised(choice.message).count - said.count)
    }
}

/// What Siri says, from the store as it is — through the moderation rules
/// (invariant 20), the filter switch read once by the caller.
enum SpokenLines {
    static func partnerStatus(in snapshot: Snapshot, reportedAt: Date?, filterEnabled: Bool,
                              now: Date = Date()) -> String {
        guard snapshot.isPaired else { return String(localized: "You're not linked with anyone yet.") }
        let name = snapshot.partnerName(filterEnabled: filterEnabled)
        if snapshot.partnerHasLeft { return String(localized: "\(name) has left your shared space.") }
        guard let theirs = snapshot.theirs else { return String(localized: "\(name) hasn't set a status yet.") }
        let shown = theirs.moderation(reportedAt: reportedAt, sealed: snapshot.partnerStatusSealed,
                                      filteredText: String(localized: "Hidden"), filterEnabled: filterEnabled)
        // In Home's order: a report outranks a surprise.
        if shown.isReported { return String(localized: "\(name)'s status is hidden on this iPhone.") }
        if snapshot.partnerStatusSealed {
            return String(localized: "\(name) has a surprise for you. Open \(AppConfig.appName) to see it.")
        }
        let ago = RelativeDateTimeFormatter().localizedString(for: min(theirs.wordsAt, now), relativeTo: now)
        let words = shown.message.isPlaceholder || shown.message.text.isEmpty ? "" : " " + shown.message.text
        return String(localized: "\(name): \(shown.emoji)\(words), \(ago).")
    }

    static func together(_ anniversary: Anniversary?, now: Date = Date()) -> String {
        guard let anniversary else {
            return String(localized: "You haven't set your date yet. Add it in \(AppConfig.appName)'s Settings.")
        }
        // As the widget counts: days in the first year, then years and days.
        let countdown = TogetherCountdown(anniversary, at: now)
        guard countdown.years > 0 || countdown.days > 0 else {
            return String(localized: "Today's your first day together.")
        }
        let count = countdown.countLine
        if let today = anniversary.milestoneToday(now) {
            return String(localized: "Happy \(today.title)! You've been together \(count).")
        }
        guard let next = anniversary.nextMilestone(after: now) else {
            return String(localized: "You've been together \(count).")
        }
        let left = anniversary.daysUntil(next.date, from: now)
        let wait = switch left {
        case 0: String(localized: "later today")
        case 1: String(localized: "tomorrow")
        default: String(localized: "in \(left) days")
        }
        return String(localized: "You've been together \(count). \(next.title) \(wait).")
    }
}
