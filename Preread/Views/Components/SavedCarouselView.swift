import SwiftUI
import GRDB

/// A horizontal carousel showing the latest 10 saved articles with thumbnails.
struct SavedCarouselView: View {
    var transitionNamespace: Namespace.ID
    let onOpenArticle: (Article) -> Void

    @State private var articles: [Article] = []
    @State private var sourceNames: [UUID: String] = [:]
    @State private var thumbnailImages: [UUID: UIImage] = [:]
    /// Tracks the thumbnailURL that was active when each thumbnail was loaded,
    /// so we can detect when a refetch produces a new image.
    @State private var loadedThumbnailURLs: [UUID: String] = [:]
    @State private var faviconImages: [UUID: UIImage] = [:]
    @State private var fetchingArticleIDs: Set<UUID> = []
    @State private var articleObservation: AnyDatabaseCancellable?

    private var visible: [Article] {
        articles.filter { thumbnailImages[$0.id] != nil }
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(visible) { article in
                            SavedCarouselCardView(
                                article: article,
                                sourceName: sourceNames[article.sourceID] ?? article.originalSourceName ?? "",
                                thumbnail: thumbnailImages[article.id],
                                favicon: faviconImages[article.sourceID],
                                isFetching: fetchingArticleIDs.contains(article.id),
                                onTap: { handleTap(article) }
                            )
                            .zoomTransitionSource(id: "saved-carousel-\(article.id)", in: transitionNamespace, cornerRadius: 16)
                            .scrollTransition { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1.0 : 0.93)
                                    .opacity(phase.isIdentity ? 1.0 : 0.85)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task { startObservation() }
    }

    // MARK: - Data loading

    private func startObservation() {
        let observation = ValueObservation.tracking { db -> ([Article], [UUID: String]) in
            let articles = try Article
                .filter(Column("isSaved") == true)
                .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                .filter(Column("thumbnailURL") != nil)
                .order(Column("savedAt").desc, Column("addedAt").desc)
                .limit(10)
                .fetchAll(db)

            var names: [UUID: String] = [:]
            let sourceIDs = Set(articles.map(\.sourceID))
            for sourceID in sourceIDs {
                if let source = try Source.fetchOne(db, key: sourceID) {
                    names[sourceID] = source.title
                }
            }
            return (articles, names)
        }
        articleObservation = observation.start(
            in: DatabaseManager.shared.dbPool,
            scheduling: .async(onQueue: .main)
        ) { _ in
        } onChange: { (newArticles, names) in
            articles = newArticles
            sourceNames = names
            loadThumbnails(for: newArticles)
            loadFavicons(for: newArticles)
        }
    }

    private func loadThumbnails(for articles: [Article]) {
        for article in articles {
            let currentURL = article.thumbnailURL
            let previousURL = loadedThumbnailURLs[article.id]

            // If the thumbnailURL changed (e.g. after a refetch), invalidate the stale image.
            if let previousURL, previousURL != currentURL {
                thumbnailImages[article.id] = nil
                ThumbnailCache.shared.removeCardThumbnail(for: article.id)
            }

            if thumbnailImages[article.id] != nil { continue }
            if let cached = ThumbnailCache.shared.cardThumbnail(for: article.id) {
                thumbnailImages[article.id] = cached
                loadedThumbnailURLs[article.id] = currentURL
                continue
            }
            let articleID = article.id
            Task {
                let image: UIImage? = await Task.detached(priority: .utility) {
                    let articleDir = ContainerPaths.articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true)

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
                    loadedThumbnailURLs[articleID] = currentURL
                    ThumbnailCache.shared.setCardThumbnail(image, for: articleID)
                }
            }
        }
    }

    private func loadFavicons(for articles: [Article]) {
        let sourceIDs = Set(articles.map(\.sourceID))
        for sourceID in sourceIDs {
            if faviconImages[sourceID] != nil { continue }
            Task {
                let image: UIImage? = await Task.detached(priority: .utility) {
                    await PageCacheService.shared.cachedFavicon(for: sourceID)
                }.value
                if let image {
                    faviconImages[sourceID] = image
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

        // Manually saved pages remember the cache level chosen at save time.
        // Feed articles use the source's current level.
        let cacheLevel: CacheLevel
        if article.sourceID == Source.savedPagesID,
           let existing = try? await DatabaseManager.shared.dbPool.read({ db in
               try CachedPage.fetchOne(db, key: article.id)
           }) {
            cacheLevel = existing.cacheLevelUsed
        } else {
            let source = try? await DatabaseManager.shared.dbPool.read { db in
                try Source.fetchOne(db, key: article.sourceID)
            }
            cacheLevel = source?.effectiveCacheLevel ?? .standard
        }
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)

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

// MARK: - Saved carousel card (with source pill)

private struct SavedCarouselCardView: View {
    let article: Article
    let sourceName: String
    let thumbnail: UIImage?
    let favicon: UIImage?
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
            .overlay(alignment: .topLeading) {
                if !sourceName.isEmpty {
                    HStack(spacing: 6) {
                        if let favicon {
                            Image(uiImage: favicon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.avatarGradient(for: sourceName))
                                    .frame(width: 16, height: 16)
                                Text(String(sourceName.prefix(1)).uppercased())
                                    .font(Theme.scaledFont(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        Text(sourceName)
                            .font(Theme.scaledFont(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 10)
                    .padding(.leading, 10)
                }
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
                        .font(Theme.scaledFont(size: 18, weight: .semibold))
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
                            .fontWeight(statusWeight)
                            .foregroundStyle(statusColor)
                    }
                    .font(Theme.scaledFont(size: 12))
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
        .accessibilityLabel("\(article.title), from \(sourceName)")
    }

    private var statusText: String {
        switch article.fetchStatus {
        case .cached, .partial:
            if let minutes = article.readingMinutes {
                return ReadingTimeFormatter.articleFormatted(minutes: minutes)
            }
            return ""
        case .fetching: return "Saving"
        case .pending: return "Pending"
        case .failed: return "Failed"
        }
    }

    private var statusWeight: Font.Weight {
        switch article.fetchStatus {
        case .cached, .partial: .regular
        case .fetching, .pending, .failed: .medium
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
