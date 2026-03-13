import SwiftUI

/// Minimal watch companion app showing a list of latest articles.
struct WatchContentView: View {
    @State private var articles: [WatchArticle] = []

    var body: some View {
        NavigationStack {
            Group {
                if articles.isEmpty {
                    emptyState
                } else {
                    articleList
                }
            }
            .navigationTitle("Preread")
        }
        .onAppear {
            articles = WatchDataStore.loadArticles()
        }
    }

    private var articleList: some View {
        List(articles) { article in
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.headline)
                    .lineLimit(3)

                HStack(spacing: 4) {
                    Text(article.sourceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let published = article.publishedAt {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(RelativeTimeFormatter.string(from: published))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No articles yet")
                .font(.headline)
            Text("Open Preread on iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
