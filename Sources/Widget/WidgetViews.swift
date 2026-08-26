import SwiftUI
import WidgetKit

// MARK: - Status

struct StatusWidgetView: View {
    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    private var status: StatusPayload? { entry.snapshot.theirs }
    private var mine: StatusPayload? { entry.snapshot.mine }
    private var isPaired: Bool { entry.snapshot.isPaired }

    /// The partner's name only once they have actually published one.
    ///
    /// `Snapshot.partnerDisplayName` falls back to "Partner", which reads
    /// fine mid-sentence and cold as a heading over an empty tile.
    private var knownName: String? {
        let name = status?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }

    /// What to call them before they've said anything.
    private var name: String { knownName ?? "Them" }

    /// Paired, but nothing has arrived from the other side yet. Its own state:
    /// it used to be lumped in with "not paired", so a widget on a freshly
    /// paired phone told the user to go and pair.
    private var isWaiting: Bool { isPaired && status == nil }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: small
            }
        }
        .widgetURL(URL(string: "redstring://open"))
        .containerBackground(for: .widget) {
            if family == .systemSmall {
                ContainerRelativeShape().fill(Theme.accent.opacity(0.14))
            } else {
                Color.clear
            }
        }
    }

    // MARK: Inline

    /// Both emoji and both names, and deliberately no message: the system
    /// gives inline a single line and truncates it without mercy, so a status
    /// sentence would lose its ending rather than shorten.
    private var inline: some View {
        guard isPaired else {
            return Text("\(AppConfig.appName): not paired")
        }
        let theirs = status.map { "\($0.emoji) \(name)" } ?? "💭 nothing yet"
        guard let mine else {
            return Text(theirs)
        }
        return Text("\(theirs) · \(mine.emoji) You")
    }

    // MARK: Circular

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let status {
                Text(status.emoji)
                    .font(.system(size: 30))
            } else if isWaiting {
                // A thought bubble, not a "go and pair" prompt: on this surface
                // the difference between "they haven't said anything" and
                // "you're not set up" is the whole message.
                Text("💭")
                    .font(.system(size: 26))
                    .opacity(0.6)
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 20))
            }
        }
    }

    // MARK: Rectangular

    /// The two of you side by side, theirs on the left, and no message text.
    ///
    /// The message used to live here and was the wrong thing to put on a lock
    /// screen: it needed two lines to be readable, still truncated often, and
    /// only ever showed one half of the pair. Two emoji answer "how are we?"
    /// in a glance, which is all this surface is for — the words are one tap
    /// away in the app.
    private var rectangular: some View {
        HStack(spacing: 0) {
            if !isPaired {
                notPaired
                Spacer(minLength: 0)
            } else {
                person(status, label: name)
                // A hairline rather than a `Divider`: in a vibrant-rendered
                // accessory widget the system divider all but disappears.
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1)
                    .padding(.vertical, 5)
                person(mine, label: "You")
            }
        }
    }

    /// One half of the pair. `nil` means paired but nothing set yet, which is
    /// its own small statement — hence a placeholder rather than a blank.
    private func person(_ status: StatusPayload?, label: String) -> some View {
        VStack(spacing: 3) {
            Text(status?.emoji ?? "💭")
                .font(.system(size: 26))

            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isPaired {
                paired
            } else {
                notPaired
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The same shape whether or not they've said anything yet.
    ///
    /// Keeping the layout and filling it with a waiting state, rather than
    /// swapping in a different view, is the point: a paired widget that goes
    /// structurally blank until the first status arrives reads as broken, and
    /// the nudge button still works the whole time — a heart is worth sending
    /// before either of you has typed a word.
    @ViewBuilder
    private var paired: some View {
        if let heading = knownName?.uppercased() {
            Text(heading)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Text(status?.emoji ?? "💭")
            .font(.system(size: 40))
            .opacity(status == nil ? 0.55 : 1)

        Text(smallMessage)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(isWaiting ? .secondary : .primary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)

        Spacer(minLength: 0)

        HStack(spacing: 4) {
            Spacer(minLength: 0)

            Button(intent: SendNudgeIntent()) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    // Matches the in-app nudge button: the heart wears the
                    // rope's crimson, not the fox's orange.
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Says what is true — they haven't posted — and what to do about it,
    /// rather than leaving the line empty.
    private var smallMessage: String {
        guard let status else { return "Nothing yet. Send yours." }
        return status.message.isEmpty ? "no message" : status.message
    }

    private var notPaired: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppConfig.appName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Open to pair")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Nudge

struct NudgeWidgetView: View {
    let entry: StatusEntry

    /// Mirrors the app's cooldown so the widget shows a check instead of a
    /// heart for a minute after sending.
    private var recentlySent: Bool {
        guard let last = entry.snapshot.lastNudgeSentAt else { return false }
        return Date().timeIntervalSince(last) < AppConfig.nudgeCooldown
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.snapshot.isPaired {
                Button(intent: SendNudgeIntent()) {
                    Image(systemName: recentlySent ? "checkmark" : "heart.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .widgetAccentable()
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 20))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Previews

#Preview("Rectangular", as: .accessoryRectangular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Circular", as: .accessoryCircular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Inline", as: .accessoryInline) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

// Paired with nothing from the other side — the state this widget used to
// render as "Open to pair".
#Preview("Small waiting", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .previewWaiting)
}

#Preview("Rectangular waiting", as: .accessoryRectangular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .previewWaiting)
}

#Preview("Circular waiting", as: .accessoryCircular) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .previewWaiting)
}

#Preview("Nudge", as: .accessoryCircular) {
    NudgeWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}
