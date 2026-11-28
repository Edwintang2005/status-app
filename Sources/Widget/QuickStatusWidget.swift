import SwiftUI
import WidgetKit

/// Your recent statuses as buttons: a tap sets one, no app needed (`SetQuickStatusIntent`).
struct QuickStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.quickStatusWidgetKind, provider: QuickStatusProvider()) { entry in
            QuickStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick status")
        .description("Set one of your recent statuses with a tap.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickStatusEntry: TimelineEntry {
    struct Choice: Hashable {
        var emoji: String
        var message: String
    }

    let date: Date
    var isPaired: Bool
    var isLocked: Bool
    var current: Choice?
    /// The current status hasn't reached iCloud yet (invariant 11).
    var unsent = false
    var choices: [Choice]

    static let sample = QuickStatusEntry(date: Date(), isPaired: true, isLocked: false,
                                         current: Choice(emoji: "☕️", message: "Coffee break"),
                                         choices: [Choice(emoji: "☕️", message: "Coffee break"),
                                                   Choice(emoji: "😴", message: "Sleeping"),
                                                   Choice(emoji: "💼", message: "At work"),
                                                   Choice(emoji: "🏠", message: "Home")])
}

/// Reads the store: a status set or sent reloads it (`WidgetContent.mineUnsent`).
/// Its one network call sends yours if it's owed (invariant 11).
struct QuickStatusProvider: TimelineProvider {
    static let choiceCount = 4

    func placeholder(in context: Context) -> QuickStatusEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (QuickStatusEntry) -> Void) {
        completion(context.isPreview ? .sample : Self.entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickStatusEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            // The only widget someone may have: it can't leave sending to the others.
            let store = SharedStore.shared
            if Self.entry().unsent, !store.fetchWaitsOutThrottle(),
               !WidgetReloadPolicy.followsSibling(reloadRequestedAt: store.widgetReloadRequestedAt) {
                await QuickStatus.sendOwed()
            }
            let entry = Self.entry()
            // Locked before first unlock, nothing else reloads this kind. Otherwise a
            // backstop: a status set on another of your devices arrives by sync.
            let wait = entry.isLocked ? WidgetReloadPolicy.whileLocked
                : entry.unsent ? WidgetReloadPolicy.whileUnsent : 6 * 3_600
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(wait))))
        }
    }

    static func entry(now: Date = Date()) -> QuickStatusEntry {
        let store = SharedStore.shared
        let mine = store.snapshot.mine.map { QuickStatusEntry.Choice(emoji: $0.emoji, message: $0.message) }
        var choices = StatusHistoryEntry.recentOwn(in: StatusHistoryLog.shared.load(), limit: choiceCount)
            .map { QuickStatusEntry.Choice(emoji: $0.emoji, message: $0.message) }
        // Topped up from the everyday presets until you've a history of your own.
        let presets = MoodGroup.allCases.flatMap { $0.moods(on: now) }.filter { !$0.isCelebration }
        for mood in presets where choices.count < choiceCount {
            let choice = QuickStatusEntry.Choice(emoji: mood.emoji, message: mood.label)
            if !choices.contains(choice) { choices.append(choice) }
        }
        return QuickStatusEntry(date: now, isPaired: store.snapshot.isPaired && !store.isLockedOut,
                                isLocked: store.isLockedOut, current: mine,
                                unsent: WidgetContent(drawing: store.snapshot).mineUnsent, choices: choices)
    }
}

struct QuickStatusWidgetView: View {
    let entry: QuickStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.isPaired {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.unsent ? "NOT SENT YET" : "YOUR STATUS")
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(entry.choices, id: \.self) { choice in
                            button(for: choice)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppConfig.appName)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                    Text(entry.isLocked ? "Unlock to set your status" : "Open to pair")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .containerBackground(for: .widget) {
            ContainerRelativeShape().fill(Theme.accent.opacity(0.14))
        }
    }

    private func button(for choice: QuickStatusEntry.Choice) -> some View {
        let isCurrent = choice == entry.current
        return Button(intent: SetQuickStatusIntent(emoji: choice.emoji, message: choice.message)) {
            HStack(spacing: 6) {
                Text(choice.emoji).font(.system(size: family == .systemSmall ? 24 : 20))
                if family == .systemMedium {
                    Text(choice.message.isEmpty ? String(localized: "no message") : choice.message)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: family == .systemSmall ? 44 : 36)
            .padding(.horizontal, family == .systemMedium ? 10 : 0)
            .background(isCurrent ? Theme.accent.opacity(0.28) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.message.isEmpty ? choice.emoji : "\(choice.emoji) \(choice.message)")
        .accessibilityValue(isCurrent ? String(localized: "Your status now") : "")
        .accessibilityHint("Sets your status")
    }
}

#Preview("Quick status small", as: .systemSmall) {
    QuickStatusWidget()
} timeline: {
    QuickStatusEntry.sample
}

#Preview("Quick status medium", as: .systemMedium) {
    QuickStatusWidget()
} timeline: {
    QuickStatusEntry.sample
}
