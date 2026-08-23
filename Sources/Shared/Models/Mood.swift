import Foundation

/// A one-tap status preset. Custom text still travels in `StatusPayload.message`;
/// presets exist so the common case is two taps rather than typing.
struct Mood: Identifiable, Hashable, Codable {
    let emoji: String
    let label: String

    var id: String { "\(emoji)-\(label)" }
}

/// Presets are grouped so the picker reads as a series of short lists rather
/// than one undifferentiated wall of emoji.
enum MoodGroup: String, CaseIterable, Identifiable {
    case feeling = "Feeling"
    case us = "Us"
    case doing = "Doing"
    case away = "Away"
    case food = "Food & drink"
    case rest = "Rest"

    var id: String { rawValue }

    var moods: [Mood] {
        switch self {
        case .feeling:
            return [
                Mood(emoji: "🥰", label: "missing you"),
                Mood(emoji: "😊", label: "happy"),
                Mood(emoji: "🤩", label: "excited"),
                Mood(emoji: "😌", label: "content"),
                Mood(emoji: "🫠", label: "melting"),
                Mood(emoji: "🥲", label: "emotional"),
                Mood(emoji: "😔", label: "a bit low"),
                Mood(emoji: "😰", label: "anxious"),
                Mood(emoji: "😤", label: "stressed"),
                Mood(emoji: "🤯", label: "overwhelmed"),
                Mood(emoji: "😐", label: "meh"),
                Mood(emoji: "🥱", label: "tired"),
                Mood(emoji: "🤒", label: "unwell"),
                Mood(emoji: "🥳", label: "celebrating"),
            ]
        case .us:
            return [
                Mood(emoji: "💌", label: "thinking of you"),
                Mood(emoji: "🫂", label: "need a hug"),
                Mood(emoji: "📞", label: "call me?"),
                Mood(emoji: "💭", label: "daydreaming"),
                Mood(emoji: "🗓️", label: "counting down"),
                Mood(emoji: "🛫", label: "see you soon"),
                Mood(emoji: "💞", label: "love you"),
                Mood(emoji: "🤍", label: "here if you need me"),
            ]
        case .doing:
            return [
                Mood(emoji: "💼", label: "working"),
                Mood(emoji: "💻", label: "heads down"),
                Mood(emoji: "📚", label: "studying"),
                Mood(emoji: "🤫", label: "on a call"),
                Mood(emoji: "🧹", label: "cleaning"),
                Mood(emoji: "🛒", label: "errands"),
                Mood(emoji: "🏋️", label: "at the gym"),
                Mood(emoji: "🏃", label: "out for a run"),
                Mood(emoji: "🎮", label: "gaming"),
                Mood(emoji: "🎧", label: "music on"),
                Mood(emoji: "📺", label: "watching something"),
                Mood(emoji: "📖", label: "reading"),
                Mood(emoji: "🎨", label: "making something"),
                Mood(emoji: "🚿", label: "in the shower"),
            ]
        case .away:
            return [
                Mood(emoji: "🚗", label: "driving"),
                Mood(emoji: "🚆", label: "commuting"),
                Mood(emoji: "✈️", label: "travelling"),
                Mood(emoji: "🧑‍💼", label: "in a meeting"),
                Mood(emoji: "📵", label: "phone away"),
                Mood(emoji: "🏥", label: "appointment"),
                Mood(emoji: "👨‍👩‍👧", label: "with family"),
                Mood(emoji: "🧑‍🤝‍🧑", label: "with friends"),
                Mood(emoji: "🌧️", label: "need space"),
                Mood(emoji: "🪫", label: "low battery"),
            ]
        case .food:
            return [
                Mood(emoji: "☕️", label: "coffee"),
                Mood(emoji: "🍳", label: "cooking"),
                Mood(emoji: "🍽️", label: "eating"),
                Mood(emoji: "🥗", label: "lunch"),
                Mood(emoji: "🍕", label: "takeaway"),
                Mood(emoji: "🧋", label: "boba run"),
                Mood(emoji: "🍺", label: "drinks"),
                Mood(emoji: "🍫", label: "snacking"),
            ]
        case .rest:
            return [
                Mood(emoji: "😴", label: "sleeping"),
                Mood(emoji: "💤", label: "napping"),
                Mood(emoji: "🛏️", label: "in bed"),
                Mood(emoji: "😪", label: "heading to bed"),
                Mood(emoji: "🌙", label: "goodnight"),
                Mood(emoji: "☀️", label: "just woke up"),
                Mood(emoji: "🛁", label: "winding down"),
                Mood(emoji: "🧘", label: "relaxing"),
            ]
        }
    }

    static var allMoods: [Mood] { allCases.flatMap(\.moods) }
}
