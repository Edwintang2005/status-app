import SwiftUI
import WidgetKit

// MARK: - Status

struct StatusWidgetView: View {
    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    private var status: StatusPayload? { entry.snapshot.theirs }
    private var mine: StatusPayload? { entry.snapshot.mine }
    private var isPaired: Bool { entry.snapshot.isPaired }

    /// The partner's name only once they've published one — the "Partner"
    /// fallback reads cold as a heading.
    private var knownName: String? {
        let name = status?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }

    /// What to call them before they've said anything.
    private var name: String { knownName ?? String(localized: "Them") }

    /// Paired, but nothing has arrived yet — distinct from "not paired".
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

    /// Emoji and names only — inline gets a single line and truncates, so no message.
    private var inline: some View {
        guard isPaired else {
            return Text("\(AppConfig.appName): not paired")
        }
        let theirs = status.map { "\($0.emoji) \(name)" } ?? String(localized: "💭 nothing yet")
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
                // Waiting is not "go and pair" — keep the states distinct.
                Text("💭")
                    .font(.system(size: 26))
                    .opacity(0.6)
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 20))
            }
        }
        .accessibilityLabel(circularSummary)
    }

    private var circularSummary: String {
        if let status { return "\(name): \(status.emoji) \(personMessage(for: status))" }
        return isWaiting ? String(localized: "Nothing from them yet") : String(localized: "Open to pair")
    }

    // MARK: Rectangular

    /// The two of you side by side, theirs on the left. Top-aligned so a
    /// wrapped message can't push its emoji out of line with the other's.
    private var rectangular: some View {
        HStack(alignment: .top, spacing: 0) {
            if !isPaired {
                notPaired
                Spacer(minLength: 0)
            } else {
                person(status, label: name)
                // Hairline, not `Divider` — the system divider vanishes in vibrant rendering.
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1)
                    .padding(.vertical, 5)
                person(mine, label: "You")
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// One half of the pair; `nil` (paired, nothing yet) draws a placeholder, not a blank.
    private func person(_ status: StatusPayload?, label: String) -> some View {
        VStack(spacing: 1.5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()

            Text(status?.emoji ?? "💭")
                .font(.system(size: 16))
                .opacity(status == nil ? 0.55 : 1)

            Text(personMessage(for: status))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .opacity(status == nil ? 0.55 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    private func personMessage(for status: StatusPayload?) -> String {
        guard let status else { return String(localized: "nothing yet") }
        return status.message.isEmpty ? String(localized: "no message") : status.message
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

    /// Same layout whether or not they've posted — a structurally blank tile
    /// reads as broken, and the nudge button works the whole time.
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
                    // Matches the in-app nudge button's crimson.
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send a nudge")
        }
    }

    private var smallMessage: String {
        guard let status else { return String(localized: "Nothing yet. Send yours.") }
        return status.message.isEmpty ? String(localized: "no message") : status.message
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

    /// Measured from `entry.date`, not `Date()`: WidgetKit renders every entry
    /// at delivery, so a wall-clock read would draw the expiry entry as a checkmark too.
    private var recentlySent: Bool {
        guard let last = entry.snapshot.lastNudgeSentAt else { return false }
        return entry.date.timeIntervalSince(last) < AppConfig.nudgeCooldown
    }

    /// The last tap never made it out; the intent can't alert, so the heart
    /// wears the news and tapping retries.
    private var recentlyFailed: Bool {
        guard let failed = entry.snapshot.lastNudgeFailedAt else { return false }
        return entry.date.timeIntervalSince(failed) < AppConfig.nudgeFailureNotice
    }

    private var symbolName: String {
        if recentlySent { return "checkmark" }
        if recentlyFailed { return "heart.slash.fill" }
        return "heart.fill"
    }

    private var accessibilityLabel: String {
        if recentlySent { return String(localized: "Nudge sent") }
        if recentlyFailed { return String(localized: "Nudge didn't send. Tap to retry") }
        return String(localized: "Send a nudge")
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.snapshot.isPaired {
                Button(intent: SendNudgeIntent()) {
                    Image(systemName: symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .widgetAccentable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
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
