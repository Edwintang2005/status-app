import Foundation

/// The status picker's draft and its rules (`MoodPickerView` draws it): what a
/// preset tap does to typed words, when Set is enabled, and what a swipe may discard.
struct StatusDraft: Equatable, Sendable {
    var emoji = ""
    var message = ""
    /// Armed only by a celebration preset, never inferred from a typed emoji,
    /// and kept while the wording is retyped.
    var celebration: CelebrationStyle?
    /// The tapped tile. Neither the emoji nor the words identify one: they're
    /// editable, and some presets share an emoji.
    var selectedPresetID: String?

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Words typed aren't lost to a stray swipe; Cancel still discards them.
    var guardsDismissal: Bool { !trimmedMessage.isEmpty }

    /// Words with no emoji: say what they'll go with.
    var needsEmojiHint: Bool { emoji.isEmpty && !trimmedMessage.isEmpty }

    /// Words alone go with 💬, as a banner reply does.
    var sentEmoji: String { emoji.isEmpty ? "💬" : emoji }

    /// A tapped tile (even the current status, re-posted on purpose), a
    /// different emoji, or words typed. A surprise needs its news.
    func hasChange(from initialEmoji: String) -> Bool {
        if celebration == .reveal, trimmedMessage.isEmpty { return false }
        return selectedPresetID != nil || emoji != initialEmoji || !trimmedMessage.isEmpty
    }

    /// A preset tile. Its label replaces the words only when that wouldn't erase
    /// hand-typed ones (empty, or still a preset's label): otherwise the tap
    /// picks its emoji. A surprise clears a preset's words — they're the news.
    /// - Returns: whether the words field should take focus (a surprise's news).
    @discardableResult
    mutating func pick(_ mood: Mood, isPresetLabel: (String) -> Bool) -> Bool {
        let untouched = trimmedMessage.isEmpty || isPresetLabel(message)
        emoji = mood.emoji
        selectedPresetID = mood.id
        celebration = mood.celebration
        if mood.celebration == .reveal {
            if untouched { message = "" }
            return true
        }
        if untouched { message = mood.label }
        return false
    }

    /// A recent status, taken whole.
    mutating func pick(recent entry: StatusHistoryEntry) {
        emoji = entry.emoji
        message = entry.message
        selectedPresetID = entry.id
        celebration = nil
    }

    /// An emoji typed by hand: no tile is chosen any more, nor its celebration.
    mutating func typedEmoji() {
        selectedPresetID = nil
        celebration = nil
    }

    mutating func capMessage() {
        if message.count > AppConfig.statusMessageMaxLength {
            message = String(message.prefix(AppConfig.statusMessageMaxLength))
        }
    }
}
