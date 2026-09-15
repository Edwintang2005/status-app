import SwiftUI

/// "3 minutes ago" for `date`, handed to `content` and re-rendered on the
/// minute boundaries of `date` itself, so the words are never a minute behind.
/// Not `Text(_:format: .relative)`: that is diffed on its inputs — a date and
/// a style that never change — so a TimelineView tick around it had nothing
/// to redraw and the words sat still.
struct RelativeTime<Content: View>: View {
    let date: Date
    @ViewBuilder let content: (String) -> Content

    init(_ date: Date, @ViewBuilder content: @escaping (String) -> Content) {
        self.date = date
        self.content = content
    }

    var body: some View {
        // A date ahead of this clock (the partner's phone running fast) has no
        // boundary to wait for; tick from now instead.
        TimelineView(.periodic(from: min(date, Date()), by: 60)) { context in
            content(date.relativeWording(asOf: context.date))
        }
    }
}

extension RelativeTime where Content == Text {
    /// The plain form: just the words.
    init(_ date: Date) {
        self.init(date) { Text($0) }
    }
}

extension Date {
    /// The wording `RelativeTime` shows, for one-shot strings (accessibility labels).
    func relativeWording(asOf now: Date = Date()) -> String {
        relativeTimeFormatter.localizedString(for: self, relativeTo: max(self, now))
    }
}

/// Truncates ("1 minute ago" until the second boundary), unlike
/// `.relative(presentation:)`, which rounds and so disagrees with the ticks.
private let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter
}()
