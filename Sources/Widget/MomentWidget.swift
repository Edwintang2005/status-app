import SwiftUI
import WidgetKit

/// The last picture your partner sent, filling the tile. Voice memos show as a
/// badge, never the tile (widgets can't play audio). Home screen only —
/// accessory families render monochrome and too small for a photo.
struct MomentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.momentWidgetKind, provider: StatusProvider(drawsPhoto: true)) { entry in
            MomentWidgetView(entry: entry)
        }
        .configurationDisplayName("Their photo")
        .description("The last photo or doodle they sent you, and a badge when a voice memo is waiting.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // Overlay pieces sit close to the edges, placed per family in `Placement`.
        .contentMarginsDisabled()
    }
}

struct MomentWidgetView: View {
    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    /// The picture only — a memo never displaces it. Moderated when the entry
    /// was built: a hidden caption or name is empty, as if there were none.
    private var moment: Moment? { entry.content.photo }
    private var unheardMemos: Int { entry.content.unheardMemos }

    var body: some View {
        ZStack {
            if let moment {
                content(for: moment)
            } else {
                empty
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if unheardMemos > 0 {
                            memoBadge
                                .padding(.top, Placement.of(family).badgeTop)
                                .padding(.trailing, Placement.of(family).badgeTrailing)
                        }
                    }
            }
        }
        .containerBackground(for: .widget) { background }
    }

    /// Says a memo is waiting; hearing it happens in the app.
    private var memoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill")
            Text("\(unheardMemos)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Theme.warmDeep, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .accessibilityLabel(unheardMemos == 1
                            ? String(localized: "1 voice memo waiting")
                            : String(localized: "\(unheardMemos) voice memos waiting"))
    }

    /// Distances from the widget's own edges (content margins are off), in points.
    private struct Placement {
        var badgeTop: CGFloat, badgeTrailing: CGFloat
        var captionLeading: CGFloat, captionBottom: CGFloat, captionWidth: CGFloat
        var composeTrailing: CGFloat, composeBottom: CGFloat

        static func of(_ family: WidgetFamily) -> Placement {
            switch family {
            case .systemMedium:
                Placement(badgeTop: 6, badgeTrailing: 16, captionLeading: 18, captionBottom: 11,
                          captionWidth: 240, composeTrailing: 16, composeBottom: 6)
            case .systemLarge:
                Placement(badgeTop: 13, badgeTrailing: 17, captionLeading: 28, captionBottom: 14,
                          captionWidth: 240, composeTrailing: 15, composeBottom: 12)
            default:
                Placement(badgeTop: 8, badgeTrailing: 10, captionLeading: 15, captionBottom: 10,
                          captionWidth: 108, composeTrailing: 0, composeBottom: 0)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for moment: Moment) -> some View {
        // Until the photo downloads, the background is the pale accent fill —
        // white-on-pale text is invisible, so style for whichever is showing.
        let onPhoto = entry.photo != nil
        let place = Placement.of(family)
        let centred = family == .systemSmall

        ZStack {
            if !moment.caption.isEmpty {
                Text(moment.caption)
                    .font(.system(size: family == .systemSmall ? 13 : 15,
                                  weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .foregroundStyle(onPhoto ? AnyShapeStyle(.white)
                                             : AnyShapeStyle(.primary))
                    .shadow(color: .black.opacity(onPhoto ? 0.55 : 0), radius: 4, y: 1)
                    .multilineTextAlignment(centred ? .center : .leading)
                    .frame(width: centred ? nil : place.captionWidth, alignment: centred ? .center : .leading)
                    .frame(maxWidth: centred ? .infinity : nil)
                    .padding(.horizontal, centred ? place.captionLeading : 0)
                    .padding(.leading, centred ? 0 : place.captionLeading)
                    .padding(.bottom, place.captionBottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: centred ? .bottom : .bottomLeading)
            }

            // systemSmall allows only one tap target (widgetURL), so no Link there.
            if family != .systemSmall {
                Link(destination: URL(string: "redstring://compose")!) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(onPhoto ? AnyShapeStyle(.white)
                                                 : AnyShapeStyle(.secondary))
                        .frame(width: 35, height: 35)
                        .background(onPhoto ? AnyShapeStyle(.black.opacity(0.35))
                                            : AnyShapeStyle(.primary.opacity(0.08)),
                                    in: Circle())
                }
                .accessibilityLabel("Send a moment")
                .padding(.trailing, place.composeTrailing)
                .padding(.bottom, place.composeBottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if unheardMemos > 0 {
                memoBadge
                    .padding(.top, place.badgeTop)
                    .padding(.trailing, place.badgeTrailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // The photo opens itself; with a memo waiting, Home (where it plays).
        .widgetURL(URL(string: unheardMemos > 0 ? "redstring://open" : "redstring://moment/\(moment.id)"))
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
        .padding(16)
        // Unpaired or memo-waiting opens the app; never deep-link an unpaired
        // user into the composer.
        .widgetURL(URL(string: entry.content.isPaired && unheardMemos == 0
                       ? "redstring://compose"
                       : "redstring://open"))
    }

    private var emptyHint: String? {
        guard entry.content.isPaired, unheardMemos == 0 else { return nil }
        return String(localized: "Tap to send the first one.")
    }

    private var emptyLabel: String {
        guard entry.content.isPaired else { return String(localized: "Open to pair") }
        if unheardMemos > 0 {
            return unheardMemos == 1
                ? String(localized: "Voice memo waiting")
                : String(localized: "\(unheardMemos) memos waiting")
        }
        return String(localized: "No photos yet")
    }

    // MARK: - Background

    @ViewBuilder
    private var background: some View {
        if let moment, let image = entry.photo {
            imageView(image)
                .accessibilityLabel(moment.senderName.isEmpty
                                    ? String(localized: "\(moment.noun) from them")
                                    : String(localized: "\(moment.noun) from \(moment.senderName)"))
                .overlay(alignment: .bottom) {
                    // Gradient only when there's a caption to keep legible; the small
                    // tile's is light and starts higher.
                    if moment.caption.isEmpty == false {
                        let small = family == .systemSmall
                        LinearGradient(colors: [.clear, .black.opacity(small ? 0.2 : 0.5)],
                                       startPoint: UnitPoint(x: 0.5, y: small ? 0.58 : 0.68),
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
    StatusEntry(date: .now, content: .preview)
}

#Preview("Moment medium", as: .systemMedium) {
    MomentWidget()
} timeline: {
    StatusEntry(date: .now, content: .preview)
}

#Preview("Moment large waiting", as: .systemLarge) {
    MomentWidget()
} timeline: {
    StatusEntry(date: .now, content: .previewWaiting)
}
#endif
