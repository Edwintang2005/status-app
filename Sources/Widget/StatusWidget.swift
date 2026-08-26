import SwiftUI
import WidgetKit

/// How the two of you are doing.
///
/// Lock screen families render vibrant — desaturated and tinted to the
/// wallpaper — so a glyph's colour can never carry meaning there. Every layout
/// with room for it pairs the emoji with a name instead.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.widgetKind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Statuses")
        .description("How you're both doing, at a glance.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
            .systemSmall,
        ])
    }
}

/// A dedicated one-tap heart for the lock screen. Separate from the status
/// widget so the tap target is unambiguous.
struct NudgeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.nudgeWidgetKind, provider: StatusProvider()) { entry in
            NudgeWidgetView(entry: entry)
        }
        .configurationDisplayName("Nudge")
        .description("Tap to send a 'thinking of you'.")
        .supportedFamilies([.accessoryCircular])
    }
}
