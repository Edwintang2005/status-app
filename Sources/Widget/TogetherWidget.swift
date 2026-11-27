import SwiftUI
import WidgetKit

/// Days together, and the red string to the next milestone (`TogetherCountdown`); a tap opens the count.
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
                VStack(spacing: 0) {
                    RedThreadView(progress: countdown.progress, seed: entry.date, bead: 3, knot: 2.5, lineWidth: 2)
                        .frame(width: 40, height: 20)
                    Text(countdown.days.formatted())
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(countdown))
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(countdown.days == 1 ? "1 day" : "\(countdown.days.formatted()) days")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .widgetAccentable()
                        Spacer(minLength: 4)
                        if let line = countdown.nextShortLine {
                            Text(line)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    RedThreadView(progress: countdown.progress, seed: entry.date, bead: 4, knot: 3, lineWidth: 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(countdown))
            default:
                small(countdown)
            }
        } else {
            placeholder
        }
    }

    /// The count, then the string from the last milestone to the next, a bead where you are.
    private func small(_ countdown: TogetherCountdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TOGETHER")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(countdown.days.formatted())
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.top, 2)
            Text(countdown.days == 1 ? "day" : "days")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            RedThreadView(progress: countdown.progress, seed: entry.date, bead: 5.5, knot: 4, lineWidth: 2.5)
                .frame(height: 32)
            HStack {
                Text(countdown.since)
                Spacer(minLength: 4)
                if let line = countdown.nextShortLine {
                    Text(line)
                        .foregroundStyle(countdown.today == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accentText))
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(countdown))
    }

    private func accessibilityText(_ countdown: TogetherCountdown) -> String {
        [countdown.daysTogether, countdown.nextLine].compactMap { $0 }.joined(separator: ". ")
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

/// The red string from the last milestone to the next: tied at the start, the
/// travelled part drawn solid, a bead where you are; on the day, it's tied off.
/// Accent-tinted on the home screen, the vibrant tint on the lock screen. Each
/// entry hangs it a little differently (`seed`), like a real thread would.
struct RedThreadView: View {
    var progress: Double?
    /// The entry's date: the same entry always draws the same slack.
    var seed: Date
    var bead: CGFloat
    var knot: CGFloat
    var lineWidth: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let done = progress ?? 0
        let tint: Color = renderingMode == .fullColor ? Theme.accent : .primary
        let beadTint: Color = renderingMode == .fullColor ? Theme.warm : .primary
        let slack = ThreadSlack(seed: seed)
        // Room for the bead and knots; every slack keeps its swing inside the frame.
        let inset = CGSize(width: knot + 1, height: bead + 1)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            RedThread(slack: slack, inset: inset).stroke(tint.opacity(0.3), style: style)
            RedThread(slack: slack, inset: inset, progress: done).stroke(tint, style: style)
                .widgetAccentable()
            RedThread.Dot(slack: slack, inset: inset, at: 0, radius: knot).fill(tint)
            RedThread.Dot(slack: slack, inset: inset, at: 1, radius: knot)
                .fill(done >= 1 ? tint : .clear)
                .overlay(RedThread.Dot(slack: slack, inset: inset, at: 1, radius: knot - lineWidth * 0.35)
                    .stroke(tint, lineWidth: max(1, lineWidth * 0.7)))
            if progress != nil, done < 1 {
                RedThread.Dot(slack: slack, inset: inset, at: done, radius: bead).fill(beadTint)
                    .widgetAccentable()
            }
        }
        .accessibilityHidden(true)
    }
}

/// A slack thread: one wave between its two knots, drawn to `progress`.
struct RedThread: Shape {
    var slack: ThreadSlack
    var inset: CGSize = .zero
    var progress: Double = 1

    func path(in rect: CGRect) -> Path {
        let whole = slack.wave(in: rect.insetBy(dx: inset.width, dy: inset.height))
        return progress >= 1 ? whole : whole.trimmedPath(from: 0, to: max(progress, 0))
    }

    /// A knot or the bead, `at` its share along the thread.
    struct Dot: Shape {
        var slack: ThreadSlack
        var inset: CGSize
        var at: Double
        var radius: CGFloat

        func path(in rect: CGRect) -> Path {
            let wave = slack.wave(in: rect.insetBy(dx: inset.width, dy: inset.height))
            let point = wave.trimmedPath(from: 0, to: min(max(at, 0.001), 1)).currentPoint ?? .zero
            return Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}
