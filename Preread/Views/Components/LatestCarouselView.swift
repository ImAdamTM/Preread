import SwiftUI
import GRDB

struct LatestCarouselView: View {
    var transitionNamespace: Namespace.ID
    let onOpenArticle: (Article) -> Void

    @State private var articles: [Article] = []
    @State private var sourceNames: [UUID: String] = [:]
    @State private var sourceCacheLevels: [UUID: CacheLevel] = [:]
    @State private var thumbnailImages: [UUID: UIImage] = [:]
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
                            CarouselCardView(
                                article: article,
                                sourceName: sourceNames[article.sourceID] ?? "",
                                thumbnail: thumbnailImages[article.id],
                                favicon: faviconImages[article.sourceID],
                                isFetching: fetchingArticleIDs.contains(article.id),
                                onTap: { handleTap(article) }
                            )
                            .matchedTransitionSource(id: "latest-carousel-\(article.id)", in: transitionNamespace) {
                                $0.clipShape(RoundedRectangle(cornerRadius: 16))
                                    .background(Theme.background)
                            }
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
        let observation = ValueObservation.tracking { db -> ([Article], [UUID: String], [UUID: CacheLevel]) in
            // Fetch a broad pool of recent cached articles with thumbnails
            let cachedStatuses = [ArticleFetchStatus.cached.rawValue,
                                  ArticleFetchStatus.partial.rawValue]
            let allArticles = try Article
                .filter(Column("sourceID") != Source.savedPagesID)
                .filter(cachedStatuses.contains(Column("fetchStatus")))
                .filter(Column("thumbnailURL") != nil)
                .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                .fetchAll(db)

            // Group by source, preserving newest-first order within each group
            var buckets: [UUID: [Article]] = [:]
            for article in allArticles {
                buckets[article.sourceID, default: []].append(article)
            }

            // Round-robin: cycle through sources, picking one article each pass.
            // Source order is by their newest article (most recent source first).
            let sortedSourceIDs = buckets.keys.sorted { a, b in
                let dateA = buckets[a]!.first.map { $0.publishedAt ?? $0.addedAt } ?? .distantPast
                let dateB = buckets[b]!.first.map { $0.publishedAt ?? $0.addedAt } ?? .distantPast
                return dateA > dateB
            }

            var result: [Article] = []
            var indices = [UUID: Int]()
            for id in sortedSourceIDs { indices[id] = 0 }

            while result.count < 30 {
                var pickedAny = false
                for sourceID in sortedSourceIDs {
                    guard result.count < 30 else { break }
                    let idx = indices[sourceID]!
                    let bucket = buckets[sourceID]!
                    if idx < bucket.count {
                        result.append(bucket[idx])
                        indices[sourceID] = idx + 1
                        pickedAny = true
                    }
                }
                if !pickedAny { break }
            }

            var names: [UUID: String] = [:]
            var cacheLevels: [UUID: CacheLevel] = [:]
            let sourceIDs = Set(result.map(\.sourceID))
            for sourceID in sourceIDs {
                if let source = try Source.fetchOne(db, key: sourceID) {
                    names[sourceID] = source.title
                    cacheLevels[sourceID] = source.effectiveCacheLevel
                }
            }
            return (result, names, cacheLevels)
        }
        articleObservation = observation.start(
            in: DatabaseManager.shared.dbPool,
            scheduling: .async(onQueue: .main)
        ) { _ in
            // Observation error — keep existing data
        } onChange: { (newArticles, names, cacheLevels) in
            articles = newArticles
            sourceNames = names
            sourceCacheLevels = cacheLevels
            loadThumbnails(for: newArticles)
            loadFavicons(for: newArticles)
        }
    }

    private func loadThumbnails(for articles: [Article]) {
        for article in articles {
            if thumbnailImages[article.id] != nil { continue }
            // Check shared card cache first
            if let cached = ThumbnailCache.shared.cardThumbnail(for: article.id) {
                thumbnailImages[article.id] = cached
                continue
            }
            let articleID = article.id
            Task {
                let image: UIImage? = await Task.detached(priority: .utility) {
                    let articleDir = ContainerPaths.articlesBaseURL.appendingPathComponent(articleID.uuidString, isDirectory: true)

                    // Prefer the large 600px thumbnail for carousel cards
                    let thumbnailPath = articleDir.appendingPathComponent("thumbnail.jpg")
                    if FileManager.default.fileExists(atPath: thumbnailPath.path),
                       let data = try? Data(contentsOf: thumbnailPath),
                       let img = UIImage(data: data) {
                        return img
                    }

                    // Fall back to the small thumb
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
            // Re-read from DB for fresh status
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

        let cacheLevel = sourceCacheLevels[article.sourceID] ?? .standard
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)

        // Reconcile with DB
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

// MARK: - Carousel card

private struct CarouselCardView: View {
    let article: Article
    let sourceName: String
    let thumbnail: UIImage?
    let favicon: UIImage?
    let isFetching: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            // Background thumbnail or gradient fallback
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.avatarGradient(for: sourceName)
                }
            }
            .frame(height: 220)
            .containerRelativeFrame(.horizontal)
            .overlay {
                // Gradient for text legibility — subtle darkening at top, stronger at bottom
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
                // Source name pill — top left
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
                            // Letter avatar fallback
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
                // Fetching spinner — top right
                if isFetching {
                    ProgressView()
                        .tint(.white)
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Article title + metadata — bottom left
                VStack(alignment: .leading, spacing: 3) {
                    if let minutes = article.readingMinutes {
                        Text(ReadingTimeFormatter.articleFormatted(minutes: minutes))
                            .font(Theme.scaledFont(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    }

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
                            .fontWeight(.medium)
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
