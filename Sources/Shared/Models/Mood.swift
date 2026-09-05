import Foundation

/// A one-tap status preset. Custom text still travels in `StatusPayload.message`;
/// presets exist so the common case is two taps rather than typing.
struct Mood: Identifiable, Hashable, Codable {
    let emoji: String
    let label: String
    /// The one anniversary preset. Picking it arms an animation on the *other*
    /// phone, and the flag survives editing the wording.
    var isCelebration: Bool = false

    var id: String { "\(emoji)-\(label)" }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return label.localizedCaseInsensitiveContains(trimmed) || emoji.contains(trimmed)
    }
}

/// Preset groups, deliberately short — the picker's emoji slot covers the long
/// tail, so each drawer holds only the things people say most. `MoodPickerView`
/// also offers search over the whole catalogue.
enum MoodGroup: String, CaseIterable, Identifiable {
    case us = "Us"
    case mood = "Mood"
    case doing = "Doing"
    case away = "Out & about"
    case rest = "Rest"

    var id: String { rawValue }

    var moods: [Mood] {
        switch self {
        case .us:
            return [
                Mood(emoji: "💗", label: "thinking about you"),
                Mood(emoji: "💭", label: "dreamt of you"),
                Mood(emoji: "💞", label: "love you"),
                Mood(emoji: "🥹", label: "miss you"),
                Mood(emoji: "🤗", label: "hug"),
                Mood(emoji: "😘", label: "kiss"),
                Mood(emoji: "🫂", label: "need a hug"),
                Mood(emoji: "🫶", label: "always here"),
                Mood(emoji: "🏅", label: "proud of you"),
                Mood(emoji: "🙇", label: "begging for forgiveness"),
                // The carrot is the joke, and the joke is the point.
                Mood(emoji: "🥕", label: "rooting for you"),
                Mood(emoji: "😍", label: "love your look"),
                Mood(emoji: "😉", label: "flirting with you"),
                Mood(emoji: "👊", label: "playfight"),
                Mood(emoji: "👂", label: "I'm listening"),
                Mood(emoji: "🤙", label: "one call away"),
                Mood(emoji: "🔮", label: "guess what"),
                Mood(emoji: "🎁", label: "got you something"),
                Mood(emoji: "🌹", label: "date night?"),
                Mood(emoji: "🎬", label: "movie tonight?"),
                // Deliberately mixed in with ordinary presets: one more thing
                // you can say, not a feature.
                Mood(emoji: "🎉", label: "happy anniversary", isCelebration: true),
                Mood(emoji: "🛫", label: "see you soon"),
                Mood(emoji: "⏳", label: "waiting for you"),
                Mood(emoji: "📸", label: "send me a pic"),
                Mood(emoji: "🍪", label: "saved you a cookie"),
                Mood(emoji: "🫖", label: "spilling tea"),
                Mood(emoji: "🤤", label: "drooling"),
            ]
        case .mood:
            var moods = [
                Mood(emoji: "🥰", label: "loving"),
                Mood(emoji: "😊", label: "happy"),
                Mood(emoji: "🤩", label: "excited"),
                Mood(emoji: "😌", label: "content"),
                Mood(emoji: "😜", label: "silly"),
                Mood(emoji: "😮", label: "surprised"),
                Mood(emoji: "🫠", label: "melting"),
                Mood(emoji: "🍀", label: "feeling lucky"),
                Mood(emoji: "😇", label: "innocent"),
                Mood(emoji: "🤞", label: "wish me luck"),
                Mood(emoji: "🫡", label: "on it"),
                Mood(emoji: "😶", label: "speechless"),
                Mood(emoji: "🤔", label: "thinking"),
                Mood(emoji: "🧠", label: "overthinking"),
                Mood(emoji: "🙃", label: "hanging in there"),
                Mood(emoji: "😐", label: "meh"),
                Mood(emoji: "🫥", label: "drained"),
                Mood(emoji: "😢", label: "sad"),
                Mood(emoji: "🧍", label: "lonely"),
                Mood(emoji: "😰", label: "anxious"),
                Mood(emoji: "😩", label: "stressed"),
                Mood(emoji: "😤", label: "frustrated"),
                Mood(emoji: "🤯", label: "overwhelmed"),
                Mood(emoji: "🥱", label: "tired"),
            ]
            // 🫩 and 🫪 are Unicode 16.0; iOS renders them only from 18.4 —
            // offering them below that shows placeholder boxes in the picker.
            if #available(iOS 18.4, *) {
                moods.append(Mood(emoji: "🫩", label: "sleep deprived"))
                moods.append(Mood(emoji: "🫪", label: "exhausted"))
            }
            return moods
        case .doing:
            return [
                Mood(emoji: "💼", label: "working"),
                Mood(emoji: "💻", label: "heads down"),
                Mood(emoji: "🏫", label: "in class"),
                Mood(emoji: "📚", label: "studying"),
                Mood(emoji: "📝", label: "exam"),
                Mood(emoji: "📞", label: "on a call"),
                Mood(emoji: "🍳", label: "cooking"),
                Mood(emoji: "🎮", label: "gaming"),
                Mood(emoji: "🍿", label: "watching a movie"),
                Mood(emoji: "📺", label: "watching tv"),
                Mood(emoji: "🎨", label: "making something"),
                Mood(emoji: "💄", label: "getting ready"),
                Mood(emoji: "🧳", label: "packing"),
                Mood(emoji: "🏋️", label: "at the gym"),
                Mood(emoji: "💪", label: "flex"),
                Mood(emoji: "🏃", label: "running"),
                Mood(emoji: "🏊", label: "swimming"),
                Mood(emoji: "🎲", label: "game night"),
                Mood(emoji: "🃏", label: "playing cards"),
                Mood(emoji: "☕️", label: "coffee break"),
                Mood(emoji: "🍽️", label: "eating"),
                Mood(emoji: "🥗", label: "dinner"),
                Mood(emoji: "🥪", label: "eating a sandwich"),
                Mood(emoji: "🥨", label: "pretzel time"),
                Mood(emoji: "🍻", label: "drinks"),
                Mood(emoji: "🍷", label: "wine o'clock"),
            ]
        case .away:
            return [
                Mood(emoji: "🏠", label: "home"),
                Mood(emoji: "🚗", label: "driving"),
                Mood(emoji: "🚆", label: "commuting"),
                Mood(emoji: "✈️", label: "travelling"),
                Mood(emoji: "🧑‍💼", label: "in a meeting"),
                Mood(emoji: "🛒", label: "shopping"),
                Mood(emoji: "📋", label: "running errands"),
                Mood(emoji: "🏥", label: "appointment"),
                Mood(emoji: "🏖️", label: "beach day"),
                Mood(emoji: "👨‍👩‍👧", label: "with family"),
                Mood(emoji: "🧑‍🤝‍🧑", label: "with friends"),
                Mood(emoji: "📵", label: "phone away"),
                Mood(emoji: "🪫", label: "low battery"),
            ]
        case .rest:
            return [
                Mood(emoji: "😴", label: "sleeping"),
                Mood(emoji: "💤", label: "napping"),
                Mood(emoji: "🛏️", label: "in bed"),
                Mood(emoji: "🌙", label: "goodnight"),
                Mood(emoji: "🌅", label: "just woke up"),
                Mood(emoji: "🚿", label: "shower"),
                Mood(emoji: "🛁", label: "bath"),
                Mood(emoji: "🧖", label: "relaxing"),
                Mood(emoji: "🛋️", label: "couch potato"),
                Mood(emoji: "🧸", label: "cosy"),
                Mood(emoji: "📴", label: "switching off"),
                Mood(emoji: "🤒", label: "sick"),
                Mood(emoji: "🤕", label: "headache"),
                Mood(emoji: "🥴", label: "hungover"),
            ]
        }
    }

    static var allMoods: [Mood] { allCases.flatMap(\.moods) }

    /// The celebration preset, so callers don't hard-code the emoji.
    static var celebration: Mood? { allMoods.first(where: \.isCelebration) }
}
