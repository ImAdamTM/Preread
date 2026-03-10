import SwiftUI
import GRDB

/// A horizontal carousel showing the latest 5 articles from a single source.
/// Reuses CarouselCardView from LatestCarouselView for visual consistency.
struct SourceCarouselView: View {
    let sourceID: UUID
    let cacheLevel: CacheLevel
    let onOpenArticle: (Article) -> Void

    @State private var articles: [Article] = []
    @State private var thumbnailImages: [UUID: UIImage] = [:]
    @State private var fetchingArticleIDs: Set<UUID> = []
    @State private var articleObservation: AnyDatabaseCancellable?

    private var visible: [Article] {
        articles.filter { thumbnailImages[$0.id] != nil }
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 3) {
                        ForEach(visible) { article in
                            SourceCarouselCardView(
                                article: article,
                                thumbnail: thumbnailImages[article.id],
                                isFetching: fetchingArticleIDs.contains(article.id),
                                onTap: { handleTap(article) }
                            )
                            .scrollTransition { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1.0 : 0.93)
                                    .opacity(phase.isIdentity ? 1.0 : 0.85)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task { startObservation() }
    }

    // MARK: - Data loading

    private func startObservation() {
        let sid = sourceID
        let observation = ValueObservation.tracking { db in
            try Article
                .filter(Column("sourceID") == sid)
                .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                .filter(Column("thumbnailURL") != nil)
                .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                .limit(10)
                .fetchAll(db)
        }
        articleObservation = observation.start(
            in: DatabaseManager.shared.dbPool,
            scheduling: .async(onQueue: .main)
        ) { _ in
            // Observation error — keep existing data
        } onChange: { newArticles in
            articles = newArticles
            loadThumbnails(for: newArticles)
        }
    }

    private func loadThumbnails(for articles: [Article]) {
        for article in articles {
            if thumbnailImages[article.id] != nil { continue }
            let articleID = article.id
            Task {
                let image: UIImage? = await Task.detached(priority: .utility) {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let articleDir = appSupport.appendingPathComponent("preread/articles/\(articleID.uuidString)", isDirectory: true)

                    let thumbnailPath = articleDir.appendingPathComponent("thumbnail.jpg")
                    if FileManager.default.fileExists(atPath: thumbnailPath.path),
                       let data = try? Data(contentsOf: thumbnailPath),
                       let img = UIImage(data: data) {
                        return img
                    }

                    let thumbPath = articleDir.appendingPathComponent("thumb.jpg")
                    if FileManager.default.fileExists(atPath: thumbPath.path),
                       let data = try? Data(contentsOf: thumbPath),
                       let img = UIImage(data: data) {
                        return img
                    }

                    return nil
                }.value

                if let image {
                    thumbnailImages[articleID] = image
                }
            }
        }
    }

    // MARK: - Tap handling

    private func handleTap(_ article: Article) {
        Task {
            let current: Article
            if let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
                try Article.fetchOne(db, key: article.id)
            }) {
                current = fresh
            } else {
                current = article
            }

            switch current.fetchStatus {
            case .cached, .partial:
                let hasContent = await PageCacheService.shared.hasCachedContent(for: current)
                if hasContent {
                    onOpenArticle(current)
                } else {
                    await fetchArticleInline(current)
                }
            case .pending:
                await fetchArticleInline(current)
            case .fetching, .failed:
                break
            }
        }
    }

    private func fetchArticleInline(_ article: Article) async {
        fetchingArticleIDs.insert(article.id)

        let level = cacheLevel
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: level)

        if let updated = try? await DatabaseManager.shared.dbPool.read({ db in
            try Article.fetchOne(db, key: article.id)
        }) {
            if updated.fetchStatus == .cached || updated.fetchStatus == .partial {
                onOpenArticle(updated)
            }
        }

        fetchingArticleIDs.remove(article.id)
    }
}

// MARK: - Source carousel card (no source pill since it's all one source)

private struct SourceCarouselCardView: View {
    let article: Article
    let thumbnail: UIImage?
    let isFetching: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.avatarGradient(for: article.title)
                }
            }
            .frame(height: 220)
            .containerRelativeFrame(.horizontal)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.3), location: 0),
                        .init(color: .black.opacity(0), location: 0.25),
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.6), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .topTrailing) {
                if isFetching {
                    ProgressView()
                        .tint(.white)
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            length * 0.78
                        }
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

                    HStack(spacing: 0) {
                        if let published = article.publishedAt {
                            Text(RelativeTimeFormatter.string(from: published))
                            Text(" · ")
                        }
                        Text(statusText)
                            .fontWeight(.medium)
                            .foregroundStyle(statusColor)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel(article.title)
    }

    private var statusText: String {
        switch article.fetchStatus {
        case .cached, .partial: "Saved"
        case .fetching: "Saving"
        case .pending: "Pending"
        case .failed: "Failed"
        }
    }

    private var statusColor: Color {
        switch article.fetchStatus {
        case .cached, .partial, .fetching: .white.opacity(0.7)
        case .pending: Theme.warning
        case .failed: Theme.danger
        }
    }
}
