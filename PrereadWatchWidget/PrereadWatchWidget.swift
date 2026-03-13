import SwiftUI
import WidgetKit

struct PrereadWatchWidget: Widget {
    let kind = "PrereadWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchTimelineProvider()) { entry in
            WatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Latest Articles")
        .description("See the latest articles from your sources.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}
