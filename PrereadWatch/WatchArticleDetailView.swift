import SwiftUI
import WatchConnectivity

/// Detail view for an article, showing excerpt text and open-on-iPhone action.
struct WatchArticleDetailView: View {
    let article: WatchArticle

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
                        Text(RelativeTimeFormatter.string(from: published))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                if let excerpt = article.excerpt {
                    Text(excerpt)
                        .font(.body)
                } else {
                    Text("Open on iPhone to read the full article.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .italic()
                }

                Divider()

                Button {
                    openOnPhone()
                } label: {
                    Label("Open on iPhone", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func openOnPhone() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["action": "openOnPhone", "articleID": article.id.uuidString],
            replyHandler: nil
        )
    }
}
