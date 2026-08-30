import SwiftUI
import WidgetKit

/// How the two of you are doing. Lock screen families render vibrant
/// (desaturated), so colour never carries meaning there.
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

/// One-tap heart for the lock screen; separate widget so the tap target is unambiguous.
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
