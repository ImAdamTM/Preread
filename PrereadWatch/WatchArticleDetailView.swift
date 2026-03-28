import SwiftUI
import WatchConnectivity

/// Detail view for an article, showing excerpt text with save and share actions.
struct WatchArticleDetailView: View {
    let article: WatchArticle
    @State private var isSaved: Bool

    init(article: WatchArticle) {
        self.article = article
        _isSaved = State(initialValue: article.isSaved)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(article.title)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 2) {
                    Text(article.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let published = article.publishedAt {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(RelativeTimeFormatter.string(from: published))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                if let excerpt = article.excerpt {
                    Text(excerpt)
                        .font(.body)
                } else {
                    Text("No excerpt available for this article.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .italic()
                }

                Divider()

                // Save & Share actions
                HStack {
                    Button {
                        toggleSave()
                    } label: {
                        Label(isSaved ? "Saved" : "Save",
                              systemImage: isSaved ? "bookmark.fill" : "bookmark")
                    }

                    Spacer()

                    if let urlString = article.articleURL,
                       let url = URL(string: urlString) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func toggleSave() {
        isSaved.toggle()

        // Update local store optimistically so the pager reflects the change
        var articles = WatchDataStore.loadArticles()
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            articles[index].isSaved = isSaved
            WatchDataStore.saveArticles(articles)
        }

        // Tell iPhone to persist the change
        let message: [String: Any] = [
            "action": "toggleSave",
            "articleID": article.id.uuidString
        ]
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            print("[WatchDetail] toggleSave sendMessage failed: \(error)")
            WCSession.default.transferUserInfo(message)
        }
    }
}
