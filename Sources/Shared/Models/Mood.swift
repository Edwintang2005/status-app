import Foundation

/// A one-tap status preset. Custom text still travels in `StatusPayload.message`;
/// presets exist so the common case is two taps rather than typing.
struct Mood: Identifiable, Hashable, Codable {
    let emoji: String
    let label: String
    /// Marks the one preset that means "we made it another month/year". Picking
    /// it arms an animation on the *other* phone — see `CelebrationOverlay` —
    /// and the flag survives editing the wording, so "happy 3 months" and
    /// "one year today" both still land as a celebration.
    var isCelebration: Bool = false

    var id: String { "\(emoji)-\(label)" }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return label.localizedCaseInsensitiveContains(trimmed) || emoji.contains(trimmed)
    }
}

/// Presets are grouped so the picker reads as a series of short lists rather
/// than one undifferentiated wall of emoji. The catalogue is large enough that
/// `MoodPickerView` offers a search field over it.
enum MoodGroup: String, CaseIterable, Identifiable {
    case mood = "Mood"
    case us = "Us"
    case doing = "Doing"
    case away = "Out & about"
    case food = "Food & drink"
    case rest = "Rest"

    var id: String { rawValue }

    var moods: [Mood] {
        switch self {
        case .mood:
            var moods = [
                Mood(emoji: "🥰", label: "loving"),
                Mood(emoji: "🥹", label: "miss you"),
                Mood(emoji: "🥺", label: "need you now"),
                Mood(emoji: "😊", label: "happy"),
                Mood(emoji: "😄", label: "overjoyed"),
                Mood(emoji: "🤩", label: "excited"),
                Mood(emoji: "😌", label: "content"),
                Mood(emoji: "😜", label: "silly"),
                Mood(emoji: "😮", label: "surprised"),
                Mood(emoji: "🫠", label: "melting"),
                Mood(emoji: "🥳", label: "celebrating"),
                Mood(emoji: "😤", label: "determined"),
                Mood(emoji: "💪", label: "powering through"),
                Mood(emoji: "🍀", label: "feeling lucky"),
                Mood(emoji: "😇", label: "innocent"),
                Mood(emoji: "🤔", label: "thinking"),
                Mood(emoji: "🧠", label: "overthinking"),
                Mood(emoji: "😳", label: "flustered"),
                Mood(emoji: "😬", label: "awkward"),
                Mood(emoji: "🙃", label: "hanging in there"),
                Mood(emoji: "🎢", label: "up and down"),
                Mood(emoji: "😑", label: "bored"),
                Mood(emoji: "😐", label: "meh"),
                Mood(emoji: "🫥", label: "drained"),
                Mood(emoji: "😢", label: "sad"),
                Mood(emoji: "😭", label: "crying"),
                Mood(emoji: "🥲", label: "emotional"),
                Mood(emoji: "🧍", label: "lonely"),
                Mood(emoji: "😟", label: "worried"),
                Mood(emoji: "😰", label: "anxious"),
                Mood(emoji: "😩", label: "stressed"),
                Mood(emoji: "😮‍💨", label: "frustrated"),
                Mood(emoji: "😠", label: "angry"),
                Mood(emoji: "🤯", label: "overwhelmed"),
                Mood(emoji: "🙅", label: "leave me alone"),
                Mood(emoji: "😪", label: "sleepy"),
                Mood(emoji: "🥱", label: "tired"),
            ]
            // 🫪 is Unicode 16.0, which iOS renders only from 18.4 — offering
            // it below that shows a placeholder box in the picker. A partner
            // on an older build still sees the box if this arrives on their
            // status; that's the emoji's floor, not something we can gate.
            if #available(iOS 18.4, *) {
                moods.append(Mood(emoji: "🫪", label: "exhausted"))
            }
            return moods
        case .us:
            return [
                Mood(emoji: "💌", label: "thinking of you"),
                Mood(emoji: "💗", label: "sending a heart"),
                Mood(emoji: "🤗", label: "hug"),
                Mood(emoji: "😘", label: "kiss"),
                Mood(emoji: "🫂", label: "need a hug"),
                Mood(emoji: "🤝", label: "hold my hand"),
                Mood(emoji: "🫶", label: "always here"),
                // The carrot is the joke, and the joke is the point.
                Mood(emoji: "🥕", label: "rooting for you"),
                Mood(emoji: "🏅", label: "proud of you"),
                Mood(emoji: "😍", label: "love your look"),
                Mood(emoji: "👂", label: "I'm listening"),
                Mood(emoji: "📞", label: "one call away"),
                Mood(emoji: "🫖", label: "spilling tea"),
                Mood(emoji: "🥊", label: "playfight"),
                Mood(emoji: "😉", label: "flirting with you"),
                Mood(emoji: "🌹", label: "date night?"),
                Mood(emoji: "🎬", label: "movie tonight?"),
                Mood(emoji: "🚶", label: "walk with me?"),
                Mood(emoji: "🎁", label: "got you something"),
                Mood(emoji: "🍪", label: "saved you one"),
                Mood(emoji: "🌻", label: "you'd love this"),
                Mood(emoji: "📸", label: "send me a pic"),
                Mood(emoji: "💭", label: "dreamt of you"),
                Mood(emoji: "🔮", label: "guess what"),
                Mood(emoji: "🐻", label: "be my little spoon"),
                Mood(emoji: "🗓️", label: "counting down"),
                // Deliberately sitting in the middle of the ordinary presets
                // rather than in a section of its own: it should read as one
                // more thing you can say, not as a feature.
                Mood(emoji: "🎉", label: "happy anniversary", isCelebration: true),
                Mood(emoji: "🛫", label: "see you soon"),
                Mood(emoji: "💞", label: "love you"),
            ]
        case .doing:
            return [
                Mood(emoji: "💼", label: "working"),
                Mood(emoji: "💻", label: "heads down"),
                Mood(emoji: "🧑‍🏫", label: "in class"),
                Mood(emoji: "📚", label: "studying"),
                Mood(emoji: "📖", label: "reading"),
                Mood(emoji: "🤫", label: "on a call"),
                Mood(emoji: "🧹", label: "cleaning"),
                Mood(emoji: "🍳", label: "cooking"),
                Mood(emoji: "🎮", label: "gaming"),
                Mood(emoji: "🎧", label: "music on"),
                Mood(emoji: "🍿", label: "watching a movie"),
                Mood(emoji: "📺", label: "watching something"),
                Mood(emoji: "📱", label: "on my phone"),
                Mood(emoji: "🎨", label: "making something"),
                Mood(emoji: "✍️", label: "writing"),
                Mood(emoji: "🧁", label: "baking"),
                Mood(emoji: "🧺", label: "laundry day"),
                Mood(emoji: "🌱", label: "gardening"),
                Mood(emoji: "🎸", label: "practising"),
                Mood(emoji: "🧩", label: "puzzling"),
                Mood(emoji: "🛠️", label: "fixing things"),
                Mood(emoji: "🗒️", label: "planning"),
                Mood(emoji: "🎲", label: "game night"),
                Mood(emoji: "🐶", label: "walking the dog"),
                Mood(emoji: "💄", label: "getting ready"),
                Mood(emoji: "🦸", label: "saving the world"),
                Mood(emoji: "🏋️", label: "at the gym"),
                Mood(emoji: "🏃", label: "working out"),
                Mood(emoji: "🤸", label: "yoga"),
            ]
        case .away:
            return [
                Mood(emoji: "🚗", label: "driving"),
                Mood(emoji: "🚆", label: "commuting"),
                Mood(emoji: "✈️", label: "travelling"),
                Mood(emoji: "🧳", label: "work trip"),
                Mood(emoji: "🧑‍💼", label: "in a meeting"),
                Mood(emoji: "🛒", label: "shopping"),
                Mood(emoji: "⛽️", label: "running errands"),
                Mood(emoji: "💈", label: "haircut"),
                Mood(emoji: "🏥", label: "appointment"),
                Mood(emoji: "🏖️", label: "beach day"),
                Mood(emoji: "🥾", label: "hiking"),
                Mood(emoji: "🌳", label: "in the park"),
                Mood(emoji: "🎶", label: "at a gig"),
                Mood(emoji: "🏟️", label: "at a game"),
                Mood(emoji: "🌏", label: "exploring"),
                Mood(emoji: "📵", label: "phone away"),
                Mood(emoji: "👨‍👩‍👧", label: "with family"),
                Mood(emoji: "🧑‍🤝‍🧑", label: "with friends"),
                Mood(emoji: "🌧️", label: "need space"),
                Mood(emoji: "🪫", label: "low battery"),
                Mood(emoji: "💸", label: "no money"),
            ]
        case .food:
            return [
                Mood(emoji: "☕️", label: "coffee break"),
                Mood(emoji: "🥞", label: "brunch"),
                Mood(emoji: "🍽️", label: "eating"),
                Mood(emoji: "🤤", label: "hungry"),
                Mood(emoji: "🥗", label: "lunch"),
                Mood(emoji: "🍕", label: "takeaway"),
                Mood(emoji: "🍜", label: "ramen night"),
                Mood(emoji: "🌮", label: "taco time"),
                Mood(emoji: "🧋", label: "boba run"),
                Mood(emoji: "🍻", label: "drinks"),
                Mood(emoji: "🍷", label: "wine o'clock"),
                Mood(emoji: "🍫", label: "snacking"),
                Mood(emoji: "🍦", label: "ice cream"),
                Mood(emoji: "🍰", label: "something sweet"),
                Mood(emoji: "🍎", label: "being healthy"),
                Mood(emoji: "🍔", label: "cheat day"),
            ]
        case .rest:
            return [
                Mood(emoji: "😴", label: "sleeping"),
                Mood(emoji: "💤", label: "napping"),
                Mood(emoji: "🛏️", label: "in bed"),
                Mood(emoji: "🌙", label: "goodnight"),
                Mood(emoji: "☀️", label: "just woke up"),
                Mood(emoji: "🚿", label: "shower"),
                Mood(emoji: "🛁", label: "bath"),
                Mood(emoji: "🛀", label: "bath together"),
                Mood(emoji: "💆", label: "massage"),
                Mood(emoji: "🧘", label: "meditating"),
                Mood(emoji: "😌", label: "relaxing"),
                Mood(emoji: "🛋️", label: "couch potato"),
                Mood(emoji: "🧸", label: "cosy"),
                Mood(emoji: "📴", label: "switching off"),
                Mood(emoji: "🌅", label: "early night"),
                Mood(emoji: "🚽", label: "toilet"),
                Mood(emoji: "🤒", label: "sick"),
                Mood(emoji: "🤕", label: "headache"),
                Mood(emoji: "🤢", label: "stomachache"),
                Mood(emoji: "🥴", label: "hungover"),
                Mood(emoji: "😵", label: "fainted"),
            ]
        }
    }

    static var allMoods: [Mood] { allCases.flatMap(\.moods) }

    /// The celebration preset, for anything that needs to describe it without
    /// hard-coding the emoji — currently the hint in `MoodPickerView`.
    static var celebration: Mood? { allMoods.first(where: \.isCelebration) }
}
