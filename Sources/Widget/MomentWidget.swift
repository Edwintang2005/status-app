import SwiftUI
import WidgetKit

/// The last picture your partner sent, filling the tile. Voice memos show as a
/// badge, never the tile (widgets can't play audio). Home screen only —
/// accessory families render monochrome and too small for a photo.
struct MomentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.momentWidgetKind, provider: StatusProvider()) { entry in
            MomentWidgetView(entry: entry)
        }
        .configurationDisplayName("Their photo")
        .description("The last photo or doodle they sent you, and a badge when a voice memo is waiting.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MomentWidgetView: View {
    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    /// The picture only — a memo never displaces it.
    private var moment: Moment? { entry.snapshot.latestPartnerVisualMoment }
    private var unheardMemos: Int { entry.snapshot.unheardVoiceMemoCount }

    var body: some View {
        ZStack {
            if let moment {
                content(for: moment)
            } else {
                empty
            }
        }
        .overlay(alignment: .topTrailing) {
            if unheardMemos > 0 { memoBadge }
        }
        .containerBackground(for: .widget) { background }
    }

    /// Says a memo is waiting; hearing it happens in the app.
    private var memoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill")
            if unheardMemos > 1 {
                Text("\(unheardMemos)").monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Theme.warm, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(9)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 8) {
                if !moment.caption.isEmpty {
                    Text(moment.caption)
                        .font(.system(size: family == .systemSmall ? 13 : 15,
                                      weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                }

                Spacer(minLength: 0)

                // systemSmall allows only one tap target (widgetURL), so no Link there.
                if family != .systemSmall {
                    Link(destination: URL(string: "redstring://compose")!) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .widgetURL(URL(string: "redstring://open"))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: unheardMemos > 0 ? "waveform" : "photo.on.rectangle.angled")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(emptyLabel)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            if let hint = emptyHint, family != .systemSmall {
                Text(hint)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        // Unpaired or memo-waiting opens the app; never deep-link an unpaired
        // user into the composer.
        .widgetURL(URL(string: entry.snapshot.isPaired && unheardMemos == 0
                       ? "redstring://compose"
                       : "redstring://open"))
    }

    private var emptyHint: String? {
        guard entry.snapshot.isPaired, unheardMemos == 0 else { return nil }
        return "Tap to send the first one."
    }

    private var emptyLabel: String {
        guard entry.snapshot.isPaired else { return "Open to pair" }
        if unheardMemos > 0 {
            return unheardMemos == 1 ? "Voice memo waiting" : "\(unheardMemos) memos waiting"
        }
        return "No photos yet"
    }

    // MARK: - Background

    @ViewBuilder
    private var background: some View {
        if let moment, let image = MomentStore.shared.thumbnail(for: moment.id) {
            imageView(image)
                .overlay(alignment: .bottom) {
                    // Gradient only when there's a caption to keep legible.
                    if moment.caption.isEmpty == false {
                        LinearGradient(colors: [.clear, .black.opacity(0.5)],
                                       startPoint: UnitPoint(x: 0.5, y: 0.68),
                                       endPoint: .bottom)
                    }
                }
        } else {
            ContainerRelativeShape().fill(Theme.accent.opacity(0.14))
        }
    }


    @ViewBuilder
    private func imageView(_ image: UIImage) -> some View {
        // `widgetAccentedRenderingMode` exists on `Image` only, so apply it
        // before `scaledToFill()` erases the concrete type.
        let base: Image = Image(uiImage: image).resizable()
        if #available(iOS 18.0, *) {
            // Keeps the photo full-colour on tinted home screens.
            base.widgetAccentedRenderingMode(.fullColor).scaledToFill()
        } else {
            base.scaledToFill()
        }
    }
}

#if DEBUG
#Preview("Moment small", as: .systemSmall) {
    MomentWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Moment medium", as: .systemMedium) {
    MomentWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .preview)
}

#Preview("Moment large waiting", as: .systemLarge) {
    MomentWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .previewWaiting)
}
#endif
