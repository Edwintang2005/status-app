import Foundation

/// A one-tap status preset. Custom text still travels in `StatusPayload.message`;
/// presets exist so the common case is two taps rather than typing.
struct Mood: Identifiable, Hashable, Codable {
    let emoji: String
    let label: String

    var id: String { "\(emoji)-\(label)" }
}

/// Presets are grouped so the picker reads as a short list rather than a wall
/// of emoji.
enum MoodGroup: String, CaseIterable, Identifiable {
    case feeling = "Feeling"
    case doing = "Doing"
    case away = "Away"
    case rest = "Rest"

    var id: String { rawValue }

    var moods: [Mood] {
        switch self {
        case .feeling:
            return [
                Mood(emoji: "🥰", label: "missing you"),
                Mood(emoji: "😊", label: "happy"),
                Mood(emoji: "🤩", label: "excited"),
                Mood(emoji: "🫠", label: "melting"),
                Mood(emoji: "😔", label: "a bit low"),
                Mood(emoji: "😤", label: "stressed"),
                Mood(emoji: "🥱", label: "tired"),
                Mood(emoji: "🤒", label: "unwell"),
            ]
        case .doing:
            return [
                Mood(emoji: "💼", label: "working"),
                Mood(emoji: "📚", label: "studying"),
                Mood(emoji: "🍳", label: "cooking"),
                Mood(emoji: "🏋️", label: "at the gym"),
                Mood(emoji: "🎮", label: "gaming"),
                Mood(emoji: "🎧", label: "music on"),
                Mood(emoji: "📺", label: "watching something"),
                Mood(emoji: "🛒", label: "running errands"),
            ]
        case .away:
            return [
                Mood(emoji: "🚗", label: "commuting"),
                Mood(emoji: "✈️", label: "travelling"),
                Mood(emoji: "🤫", label: "in a meeting"),
                Mood(emoji: "📵", label: "phone away"),
                Mood(emoji: "🍽️", label: "eating out"),
                Mood(emoji: "👨‍👩‍👧", label: "with family"),
                Mood(emoji: "🧑‍🤝‍🧑", label: "with friends"),
                Mood(emoji: "🌧️", label: "need space"),
            ]
        case .rest:
            return [
                Mood(emoji: "😴", label: "sleeping"),
                Mood(emoji: "🛏️", label: "in bed"),
                Mood(emoji: "☕️", label: "just woke up"),
                Mood(emoji: "🛁", label: "winding down"),
            ]
        }
    }

    static var allMoods: [Mood] { allCases.flatMap(\.moods) }
}
