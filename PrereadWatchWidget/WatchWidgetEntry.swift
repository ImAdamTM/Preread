import WidgetKit

struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    let articles: [WatchArticle]

    var isEmpty: Bool { articles.isEmpty }
}
