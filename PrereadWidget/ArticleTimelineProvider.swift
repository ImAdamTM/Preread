import WidgetKit

struct ArticleTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = ArticleWidgetEntry
    typealias Intent = SelectSourceIntent

    func placeholder(in context: Context) -> ArticleWidgetEntry {
        ArticleWidgetEntry(
            date: Date(),
            articles: [placeholderArticle],
            configuration: SelectSourceIntent()
        )
    }

    func snapshot(for configuration: SelectSourceIntent, in context: Context) async -> ArticleWidgetEntry {
        makeEntry(for: configuration, context: context)
    }

    func timeline(for configuration: SelectSourceIntent, in context: Context) async -> Timeline<ArticleWidgetEntry> {
        let entry = makeEntry(for: configuration, context: context)

        if entry.isEmpty {
            // No data — retry in 15 minutes
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            return Timeline(entries: [entry], policy: .after(nextUpdate))
        }

        // Generate slideshow entries: one per article, spaced apart
        // WidgetKit crossfades between entries automatically
        var entries: [ArticleWidgetEntry] = []
        let interval: TimeInterval = 10

        for index in entry.articles.indices {
            let entryDate = entry.date.addingTimeInterval(Double(index) * interval)
            // Rotate the articles array so the current article is first
            let rotated = Array(entry.articles[index...]) + Array(entry.articles[..<index])
            entries.append(ArticleWidgetEntry(
                date: entryDate,
                articles: rotated,
                configuration: configuration
            ))
        }

        // Refresh timeline every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        return Timeline(entries: entries, policy: .after(nextUpdate))
    }

    // MARK: - Private

    private func makeEntry(for configuration: SelectSourceIntent, context: Context) -> ArticleWidgetEntry {
        guard let provider = WidgetDataProvider() else {
            return ArticleWidgetEntry(date: Date(), articles: [], configuration: configuration)
        }

        var sourceID: UUID? = nil
        if !configuration.source.isAllSources,
           let id = UUID(uuidString: configuration.source.id) {
            // Verify source still exists; fall back to all sources if deleted
            sourceID = provider.sourceExists(id) ? id : nil
        }

        let family = context.family
        let limit = articleCount(for: family)
        let accessory = isAccessoryFamily(family)
        let results = provider.fetchArticles(sourceID: sourceID, limit: limit, requireThumbnail: !accessory)

        let widgetArticles: [WidgetArticle] = results.compactMap { item in
            let thumbnail = accessory ? nil : provider.loadThumbnail(for: item.article.id)
            // For system widgets, skip articles without thumbnail images on disk
            if !accessory, thumbnail == nil { return nil }

            let favicon = accessory ? nil : provider.loadFavicon(for: item.article.sourceID)
            let deepLink = URL(string: "preread://article/\(item.article.id.uuidString)")!

            return WidgetArticle(
                id: item.article.id,
                title: item.article.title,
                sourceName: item.sourceName,
                publishedAt: item.article.publishedAt,
                readingMinutes: item.article.readingMinutes,
                thumbnailImage: thumbnail,
                faviconImage: favicon,
                deepLinkURL: deepLink
            )
        }

        return ArticleWidgetEntry(
            date: Date(),
            articles: Array(widgetArticles.prefix(limit)),
            configuration: configuration
        )
    }

    private func isAccessoryFamily(_ family: WidgetFamily) -> Bool {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            return true
        default:
            return false
        }
    }

    private func articleCount(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 5
        case .systemMedium: return 8
        case .systemLarge: return 10
        case .systemExtraLarge: return 10
        case .accessoryRectangular: return 3
        case .accessoryCircular: return 1
        case .accessoryInline: return 3
        case .accessoryCorner: return 1
        @unknown default: return 5
        }
    }

    private var placeholderArticle: WidgetArticle {
        WidgetArticle(
            id: UUID(),
            title: "Article Title",
            sourceName: "Source",
            publishedAt: Date(),
            readingMinutes: 5,
            thumbnailImage: nil,
            faviconImage: nil,
            deepLinkURL: URL(string: "preread://")!
        )
    }
}
