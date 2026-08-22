import SwiftUI
import WidgetKit

// MARK: - Status

struct StatusWidgetView: View {
    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    private var status: StatusPayload? { entry.snapshot.theirs }
    private var name: String { entry.snapshot.partnerDisplayName }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: small
            }
        }
        .widgetURL(URL(string: "tether://open"))
        .containerBackground(for: .widget) {
            if family == .systemSmall {
                ContainerRelativeShape().fill(Theme.accent.opacity(0.14))
            } else {
                Color.clear
            }
        }
    }

    // MARK: Inline

    private var inline: some View {
        if let status {
            return Text("\(status.emoji) \(name): \(status.message)")
        } else {
            return Text("\(AppConfig.appName): not paired")
        }
    }

    // MARK: Circular

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let status {
                VStack(spacing: 0) {
                    Text(status.emoji)
                        .font(.system(size: 22))
                    Text(status.updatedAt, style: .relative)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 2)
                }
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 20))
            }
        }
    }

    // MARK: Rectangular

    private var rectangular: some View {
        HStack(alignment: .center, spacing: 8) {
            if let status {
                Text(status.emoji)
                    .font(.system(size: 30))

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .widgetAccentable()
                        .lineLimit(1)

                    Text(status.message.isEmpty ? "no message" : status.message)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(status.updatedAt, style: .relative)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            } else {
                notPaired
            }
        }
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                Text(name.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(status.emoji)
                    .font(.system(size: 40))

                Text(status.message.isEmpty ? "no message" : status.message)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Text(status.updatedAt, style: .relative)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Button(intent: SendNudgeIntent()) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Theme.warm, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                notPaired
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview("Nudge", as: .accessoryCircular) {
    NudgeWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}
