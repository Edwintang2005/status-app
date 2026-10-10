import Foundation

/// Which full-screen animation a celebration status plays on the other phone.
/// Travels encrypted beside `isCelebration`; a build that doesn't know the field
/// (or a style from a newer build) plays `.confetti` with the same words.
enum CelebrationStyle: String, CaseIterable, Codable, Sendable {
    case confetti
    case hearts
    case trophy
    /// Candles to blow out before the words appear.
    case birthday
    /// The words stay sealed everywhere until scratched open in the app.
    case reveal
    case fireworks
    case snow

    /// What the screen says when they sent no words (or the words can't be shown).
    var defaultHeadline: String {
        switch self {
        case .confetti: String(localized: "Happy anniversary")
        case .hearts: String(localized: "Love you")
        case .trophy: String(localized: "You did it!")
        case .birthday: String(localized: "Happy birthday")
        case .reveal: String(localized: "Surprise!")
        case .fireworks: String(localized: "Happy New Year")
        case .snow: String(localized: "Merry Christmas")
        }
    }
}

extension StatusPayload {
    /// The animation this status plays, or `nil` for an ordinary status.
    var celebration: CelebrationStyle? {
        isCelebration ? (celebrationStyle ?? .confetti) : nil
    }
}

extension Snapshot {
    /// The partner's surprise, not yet scratched open: its words stay off every
    /// surface but the reveal itself — widget, banner, Home, history.
    var partnerStatusSealed: Bool { pendingCelebration?.celebration == .reveal }

    /// The sealed status's `wordsAt`, for the history row it files.
    var sealedPartnerWordsAt: Date? { partnerStatusSealed ? theirs?.wordsAt : nil }
}

/// Celebration presets that only make sense around their day; the picker
/// shows them at the top of "Us" while they're in season.
enum SeasonalMoods {
    struct Season {
        let mood: Mood
        /// Month and day, inclusive, Gregorian; a window may wrap the new year.
        let from: (month: Int, day: Int)
        let to: (month: Int, day: Int)

        func contains(month: Int, day: Int) -> Bool {
            let value = month * 100 + day
            let start = from.month * 100 + from.day
            let end = to.month * 100 + to.day
            return start <= end ? (start...end).contains(value) : value >= start || value <= end
        }
    }

    static let seasons: [Season] = [
        Season(mood: Mood(emoji: "🎄", label: "merry christmas", celebration: .snow),
               from: (12, 1), to: (12, 26)),
        Season(mood: Mood(emoji: "🎆", label: "happy new year", celebration: .fireworks),
               from: (12, 26), to: (1, 7)),
        Season(mood: Mood(emoji: "💝", label: "happy valentine's day", celebration: .hearts),
               from: (2, 7), to: (2, 15)),
    ]

    /// In season on `date`, in this phone's own calendar day.
    static func moods(on date: Date, timeZone: TimeZone = .current) -> [Mood] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return [] }
        return seasons.filter { $0.contains(month: month, day: day) }.map(\.mood)
    }
}
