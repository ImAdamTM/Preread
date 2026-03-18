import SwiftUI
import WidgetKit

// MARK: - Accessory Rectangular

/// Shows article title, source name, and relative time.
/// Used on iOS Lock Screen and watchOS complications/Smart Stack.
struct AccessoryRectangularView: View {
    let entry: ArticleWidgetEntry

    var body: some View {
        if let article = entry.articles.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)
                    .widgetAccentable()

                HStack(spacing: 4) {
                    Text(article.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let published = article.publishedAt {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(RelativeTimeFormatter.string(from: published))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(article.deepLinkURL)
        } else {
            accessoryEmptyState
        }
    }
}

// MARK: - Accessory Circular

/// Shows the article count or app branding icon.
struct AccessoryCircularView: View {
    let entry: ArticleWidgetEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.isEmpty {
                Image(systemName: "doc.text")
                    .font(.title3)
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "doc.text.fill")
                        .font(.caption)
                        .widgetAccentable()
                    Text("\(entry.articles.count)")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                }
            }
        }
        .widgetURL(entry.articles.first?.deepLinkURL)
    }
}

// MARK: - Accessory Inline

/// Single line: "Source — Article Title" (system truncates as needed).
struct AccessoryInlineView: View {
    let entry: ArticleWidgetEntry

    var body: some View {
        if let article = entry.articles.first {
            Text("\(article.sourceName) — \(article.title)")
                .widgetURL(article.deepLinkURL)
        } else {
            Text("No articles")
        }
    }
}

// MARK: - Shared empty state

private var accessoryEmptyState: some View {
    VStack(alignment: .leading, spacing: 2) {
        Text("No articles yet")
            .font(.headline)
        Text("Open Preread")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
