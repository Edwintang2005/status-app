import SwiftUI
import WidgetKit

/// The Locket-style widget: whatever your partner last sent, filling the tile.
///
/// Home screen only. Lock screen accessory widgets are rendered monochrome and
/// are a couple of hundred points across — a photo there would be an
/// unrecognisable grey smudge, so this doesn't offer those families.
struct MomentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.momentWidgetKind, provider: StatusProvider()) { entry in
            MomentWidgetView(entry: entry)
        }
        .configurationDisplayName("Their photo")
        .description("The last photo or doodle they sent you.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MomentWidgetView: View {
    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    private var moment: Moment? { entry.snapshot.latestPartnerMoment }

    var body: some View {
        ZStack {
            if let moment {
                content(for: moment)
            } else {
                empty
            }
        }
        .containerBackground(for: .widget) { background }
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

                // Small widgets only get a single tap target (widgetURL), so
                // the compose shortcut is limited to the roomier families.
                if family != .systemSmall {
                    Link(destination: URL(string: "tether://compose")!) {
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
        .widgetURL(URL(string: "tether://open"))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(entry.snapshot.isPaired ? "No photos yet" : "Open to pair")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "tether://compose"))
    }

    // MARK: - Background

    @ViewBuilder
    private var background: some View {
        if let moment, let image = MomentStore.shared.thumbnail(for: moment.id) {
            imageView(image)
                .overlay(alignment: .bottom) {
                    // Only drawn when there's text to keep legible — an
                    // uncaptioned doodle on white shouldn't be greyed for
                    // nothing.
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
        // `widgetAccentedRenderingMode` is declared on `Image`, so it has to be
        // applied before `scaledToFill()` erases the concrete type.
        let base: Image = Image(uiImage: image).resizable()
        if #available(iOS 18.0, *) {
            // Without this the photo is flattened to the tint colour when the
            // user has a tinted home screen.
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
#endif
