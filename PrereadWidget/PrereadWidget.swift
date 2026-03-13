import WidgetKit
import SwiftUI

struct PrereadArticleWidget: Widget {
    let kind: String = "PrereadArticleWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectSourceIntent.self,
            provider: ArticleTimelineProvider()
        ) { entry in
            PrereadWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Latest Articles")
        .description("See the latest articles from your sources.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline
        ])
        .contentMarginsDisabled()
    }
}

#Preview(as: .systemMedium) {
    PrereadArticleWidget()
} timeline: {
    ArticleWidgetEntry(
        date: .now,
        articles: [],
        configuration: SelectSourceIntent()
    )
}
