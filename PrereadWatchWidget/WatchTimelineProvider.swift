import WidgetKit

struct WatchTimelineProvider: TimelineProvider {
    typealias Entry = WatchWidgetEntry

    func placeholder(in context: Context) -> WatchWidgetEntry {
        WatchWidgetEntry(
            date: Date(),
            articles: [
                WatchArticle(id: .init(), title: "Article Title", sourceName: "Source", publishedAt: Date(), readingMinutes: nil, isRead: false)
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        let articles = WatchDataStore.loadArticles()
        let entry = WatchWidgetEntry(date: Date(), articles: articles)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        let articles = WatchDataStore.loadArticles()

        if articles.isEmpty {
            let entry = WatchWidgetEntry(date: Date(), articles: [])
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
            return
        }

        // Generate slideshow entries: rotate through articles
        var entries: [WatchWidgetEntry] = []
        let interval: TimeInterval = 10
        let maxEntries = min(articles.count, 5)

        for index in 0..<maxEntries {
            let entryDate = Date().addingTimeInterval(Double(index) * interval)
            let rotated = Array(articles[index...]) + Array(articles[..<index])
            entries.append(WatchWidgetEntry(date: entryDate, articles: rotated))
        }

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: entries, policy: .after(nextUpdate)))
    }
}
