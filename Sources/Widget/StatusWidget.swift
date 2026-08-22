import SwiftUI
import WidgetKit

/// The partner's status. Lock screen families render monochrome by system
/// design, so every layout pairs the emoji with words rather than relying on
/// the glyph's colour to carry meaning.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.widgetKind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Their status")
        .description("What they're up to, at a glance.")
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
        StaticConfiguration(kind: "TetherNudgeWidget", provider: StatusProvider()) { entry in
            NudgeWidgetView(entry: entry)
        }
        .configurationDisplayName("Nudge")
        .description("Tap to send a 'thinking of you'.")
        .supportedFamilies([.accessoryCircular])
    }
}
