import Foundation

/// UserDefaults-backed store for watch articles.
/// Shared between the watch app and watch widget extension via app group.
struct WatchDataStore {
    static let suiteName = "group.streamlinelabs.preread.watch"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func saveArticles(_ articles: [WatchArticle]) {
        guard let data = try? JSONEncoder().encode(articles) else { return }
        defaults?.set(data, forKey: "articles")
    }

    static func loadArticles() -> [WatchArticle] {
        guard let data = defaults?.data(forKey: "articles"),
              let articles = try? JSONDecoder().decode([WatchArticle].self, from: data) else {
            return []
        }
        return articles
    }
}
