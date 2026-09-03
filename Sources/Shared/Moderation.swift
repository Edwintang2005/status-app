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
    static func hides(_ text: String) -> Bool {
        SharedStore.shared.contentFilterEnabled && flags(text)
    }

    static var hiddenPlaceholder: String { String(localized: "Hidden by your content filter") }
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
