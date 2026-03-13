import SwiftUI
import WidgetKit

struct WatchWidgetView: View {
    let entry: WatchWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangularView
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        case .accessoryCorner:
            cornerView
        default:
            rectangularView
        }
    }

    // MARK: - Rectangular

    private var rectangularView: some View {
        Group {
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
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No articles yet")
                        .font(.headline)
                    Text("Open Preread on iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Circular

    private var circularView: some View {
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
    }

    // MARK: - Inline

    private var inlineView: some View {
        Group {
            if let article = entry.articles.first {
                Text("\(article.sourceName) — \(article.title)")
            } else {
                Text("No articles")
            }
        }
    }

    // MARK: - Corner (watchOS only)

    private var cornerView: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "doc.text.fill")
                .font(.title3)
                .widgetAccentable()
        }
        .widgetLabel {
            if let article = entry.articles.first {
                Text(article.sourceName)
            }
        }
    }
}
