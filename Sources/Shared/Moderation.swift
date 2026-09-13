import Foundation

/// The moderation pieces App Review requires of anything carrying user content
/// (guideline 1.2): an on-device word filter, and the report that goes to the
/// developer. There is no server — every message is end-to-end encrypted in
/// the couple's own iCloud — so the filter runs where the text is readable,
/// and a report carries the content the reporter chooses to send.
enum ContentFilter {
    /// Strong profanity and slurs, matched as whole words after case and
    /// diacritic folding. Deliberately short: this hides the worst from
    /// someone who asked for it, it isn't a language model.
    static let terms: Set<String> = [
        "fuck", "fucking", "fucker", "motherfucker", "shit", "bullshit", "cunt",
        "bitch", "asshole", "arsehole", "bastard", "dick", "cock", "pussy", "twat",
        "wanker", "slut", "whore", "nigger", "nigga", "faggot", "fag", "retard",
        "retarded", "tranny", "kike", "spic", "chink", "gook", "paki", "raghead",
        "kys", "rape", "rapist",
    ]

    /// Whether the text contains a listed word. Word-level so "Scunthorpe"
    /// and "assist" pass.
    static func flags(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let folded = text.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { terms.contains(String($0)) }
    }

    /// The filter as the user has it set: on by default, off in Settings.
    /// `enabled` is injectable so the presentation helpers below stay testable.
    static func hides(_ text: String, enabled: Bool = SharedStore.shared.contentFilterEnabled) -> Bool {
        enabled && flags(text)
    }

    static var hiddenPlaceholder: String { String(localized: "Hidden by your content filter") }
    static var reportedPlaceholder: String { String(localized: "Reported") }

    /// A name someone chose for themselves, or `fallback` when it's empty or
    /// the filter hides it — names are user text too.
    static func displayName(_ name: String,
                            fallback: String,
                            enabled: Bool = SharedStore.shared.contentFilterEnabled) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hides(trimmed, enabled: enabled) else { return fallback }
        return trimmed
    }
}

// MARK: - Presentation

// Every surface that shows the partner's words goes through these — the app,
// the widgets and the notification service alike — so a report or the filter
// can't be bypassed by one screen forgetting (CLAUDE.md invariant 20).

extension StatusPayload {
    /// The partner's status as it may be shown. Reported (`reportedAt` is its
    /// `updatedAt`) hides both words and emoji; filtered swaps the words for
    /// `filteredText`. Own statuses never go through this.
    func moderated(reportedAt: Date?,
                   filteredText: String = ContentFilter.hiddenPlaceholder,
                   filterEnabled: Bool = SharedStore.shared.contentFilterEnabled) -> StatusPayload {
        var shown = self
        if let reportedAt, updatedAt == reportedAt {
            shown.emoji = "💭"
            shown.message = ContentFilter.reportedPlaceholder
        } else if ContentFilter.hides(message, enabled: filterEnabled) {
            shown.message = filteredText
        }
        return shown
    }
}

extension StatusHistoryEntry {
    /// Same rule for the log: a reported partner status keeps its slot but not its words.
    func moderated(reportedAt: Date?,
                   filterEnabled: Bool = SharedStore.shared.contentFilterEnabled) -> StatusHistoryEntry {
        guard !fromMe else { return self }
        var shown = self
        if let reportedAt, at == reportedAt {
            shown.emoji = "💭"
            shown.message = ContentFilter.reportedPlaceholder
        } else if ContentFilter.hides(message, enabled: filterEnabled) {
            shown.message = ContentFilter.hiddenPlaceholder
        }
        return shown
    }
}

extension Moment {
    /// The sender's name as it may be shown: own sends are never filtered, and
    /// a partner's name the filter hides (or that was never set) becomes `fallback`.
    func displaySenderName(fallback: String) -> String {
        if fromMe { return senderName.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ContentFilter.displayName(senderName, fallback: fallback)
    }

    /// The caption as it may be shown, or `nil` when there is none to show — a
    /// partner caption the filter hides reads as no caption.
    var displayCaption: String? {
        guard !caption.isEmpty else { return nil }
        if !fromMe, ContentFilter.hides(caption) { return nil }
        return caption
    }
}

/// A report to the developer, as an email the user sends themselves — the one
/// channel an app with no server has. The body names the pair (zone owner and
/// role) so the sender can be identified and ejected, and quotes the content.
enum Report {
    struct Details {
        var kind: String
        var identifier: String
        var senderName: String
        var text: String
        var pairing: PairingInfo?
        var reporterName: String
    }

    static func subject(for details: Details) -> String {
        "\(AppConfig.appName) report: \(details.kind)"
    }

    static func body(for details: Details) -> String {
        var lines = [
            "Report from \(AppConfig.appName). Please act within 24 hours.",
            "",
            "What: \(details.kind)",
            "Identifier: \(details.identifier)",
            "Sent by: \(details.senderName.isEmpty ? "(no name)" : details.senderName)",
            "Reported by: \(details.reporterName.isEmpty ? "(no name)" : details.reporterName)",
        ]
        if let pairing = details.pairing {
            lines.append("Pair: zone owner \(pairing.zoneOwnerName), reporter is the \(pairing.role.rawValue)")
        }
        lines.append("")
        lines.append("Content: \(details.text.isEmpty ? "(no text — see attached description)" : details.text)")
        lines.append("")
        lines.append("Add anything else you want us to know above this line.")
        return lines.joined(separator: "\n")
    }

    static func mailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppConfig.supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "body", value: body)]
        return components.url
    }

    static func mailURL(for details: Details) -> URL? {
        mailURL(subject: subject(for: details), body: body(for: details))
    }
}
