import SwiftUI
import WidgetKit

struct PrereadWidgetView: View {
    let entry: ArticleWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                AccessoryRectangularView(entry: entry)
            case .accessoryCircular:
                AccessoryCircularView(entry: entry)
            case .accessoryInline:
                AccessoryInlineView(entry: entry)
            default:
                if entry.isEmpty {
                    emptyStateView
                } else {
                    systemWidget
                }
            }
        }
    }

    // MARK: - System widget dispatch

    @ViewBuilder
    private var systemWidget: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .systemLarge:
            largeWidget
        default:
            smallWidget
        }
    }

    // MARK: - Small widget (single full-bleed card)

    @ViewBuilder
    private var smallWidget: some View {
        if let article = entry.articles.first {
            Link(destination: article.deepLinkURL) {
                WidgetCardView(article: article, compact: true)
            }
        }
    }

    // MARK: - Medium widget (single full-bleed card, wider)

    @ViewBuilder
    private var mediumWidget: some View {
        if let article = entry.articles.first {
            Link(destination: article.deepLinkURL) {
                WidgetCardView(article: article, compact: false)
            }
        }
    }

    // MARK: - Large widget (hero + list rows)

    @ViewBuilder
    private var largeWidget: some View {
        if let first = entry.articles.first {
            VStack(spacing: 0) {
                Link(destination: first.deepLinkURL) {
                    WidgetCardView(article: first, compact: false)
                }
                .frame(maxHeight: .infinity)
                .clipShape(ContainerRelativeShape())

                if entry.articles.count > 1 {
                    let listArticles = Array(entry.articles.dropFirst().prefix(3))

                    Divider().opacity(0.3)

                    VStack(spacing: 0) {
                        ForEach(Array(listArticles.enumerated()), id: \.element.id) { index, article in
                            Link(destination: article.deepLinkURL) {
                                WidgetRowView(article: article)
                            }
                            if index < listArticles.count - 1 {
                                Divider().opacity(0.2).padding(.leading, 66)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .clipShape(ContainerRelativeShape())
        }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No articles yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Open Preread to get started")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
