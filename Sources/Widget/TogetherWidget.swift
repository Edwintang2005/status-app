import SwiftUI
import WidgetKit

/// Days together and the next milestone (`TogetherCountdown`); a tap opens the count.
struct TogetherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.togetherWidgetKind, provider: TogetherProvider()) { entry in
            TogetherWidgetView(entry: entry)
        }
        .configurationDisplayName("Together")
        .description("How long you've been together, and the next milestone.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .systemSmall])
    }
}

struct TogetherEntry: TimelineEntry {
    let date: Date
    var isLocked: Bool
    var isPaired = true
    var countdown: TogetherCountdown?

    static var sample: TogetherEntry {
        let began = Anniversary(startsAt: Date().addingTimeInterval(-173 * 86_400))
        return TogetherEntry(date: Date(), isLocked: false, countdown: TogetherCountdown(began, at: Date()))
    }
}

/// The store only: a changed date reloads it (`WidgetContent.anniversary`), and
/// between changes the timeline steps through `TogetherCountdown.changes`.
struct TogetherProvider: TimelineProvider {
    func placeholder(in context: Context) -> TogetherEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (TogetherEntry) -> Void) {
        completion(context.isPreview ? .sample : Self.entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TogetherEntry>) -> Void) {
        let now = Date()
        let store = SharedStore.shared
        guard !store.isLockedOut, store.snapshot.isPaired, let anniversary = store.snapshot.anniversary else {
            // Locked before first unlock, or no date: look again soon, then hourly.
            let next = now.addingTimeInterval(store.isLockedOut ? WidgetReloadPolicy.whileLocked : WidgetReloadPolicy.settled)
            completion(Timeline(entries: [Self.entry(at: now)], policy: .after(next)))
            return
        }
        let dates = [now] + TogetherCountdown.changes(for: anniversary, after: now)
        let entries = dates.map { TogetherEntry(date: $0, isLocked: false, countdown: TogetherCountdown(anniversary, at: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func entry(at now: Date) -> TogetherEntry {
        let store = SharedStore.shared
        let countdown = store.isLockedOut || !store.snapshot.isPaired
            ? nil : store.snapshot.anniversary.map { TogetherCountdown($0, at: now) }
        return TogetherEntry(date: now, isLocked: store.isLockedOut, isPaired: store.snapshot.isPaired,
                             countdown: countdown)
    }
}

struct TogetherWidgetView: View {
    let entry: TogetherEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "redstring://together"))
            .containerBackground(for: .widget) {
                if family == .systemSmall {
                    ContainerRelativeShape().fill(Theme.accent.opacity(0.14))
                } else {
                    Color.clear
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let countdown = entry.countdown {
            switch family {
            case .accessoryInline:
                Text(countdown.daysTogether)
            case .accessoryCircular:
                VStack(spacing: -2) {
                    Text(countdown.days.formatted())
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text(countdown.days == 1 ? "day" : "days").font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .accessibilityElement(children: .combine)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(countdown.daysTogether)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .widgetAccentable()
                    if let line = countdown.nextLine {
                        Text(line).font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                small(countdown)
            }
        } else {
            placeholder
        }
    }

    private func small(_ countdown: TogetherCountdown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TOGETHER")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(countdown.days.formatted())
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(countdown.days == 1 ? "day" : "days").font(.system(.subheadline, design: .rounded, weight: .semibold))
            Spacer(minLength: 0)
            if let line = countdown.nextLine {
                Label(line, systemImage: countdown.today == nil ? "sparkles" : "heart.fill")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(countdown.today == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accentText))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var placeholder: some View {
        let words: LocalizedStringKey = entry.isLocked ? "Unlock to see"
            : entry.isPaired ? "Set your date in Settings" : "Open to pair"
        switch family {
        case .accessoryInline, .accessoryCircular:
            Image(systemName: entry.isLocked ? "lock.fill" : "infinity")
                .accessibilityLabel(Text(words))
        default:
            VStack(alignment: .leading, spacing: 3) {
                Text(AppConfig.appName)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                Text(words)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#Preview("Together small", as: .systemSmall) {
    TogetherWidget()
} timeline: {
    TogetherEntry.sample
}
