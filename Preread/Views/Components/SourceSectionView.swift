import SwiftUI
import GRDB

struct SourceSectionView: View {
    let source: Source
    let refreshState: SourceRefreshState
    var transitionNamespace: Namespace.ID
    let onViewAll: () -> Void
    let onRefresh: () -> Void
    let onEditName: () -> Void
    let onRemove: () -> Void
    let onOpenArticle: (Article) -> Void

    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Namespace private var namespace
    @State private var articles: [Article] = []
    @State private var totalArticleCount: Int = 0
    @State private var totalReadingMinutes: Int = 0
    @State private var cachedFavicon: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var isAutoCaching = false
    @State private var articleObservation: AnyDatabaseCancellable?
    @AppStorage("articleLimit") private var articleLimit: Int = 25

    var body: some View {
        Section {
            if articles.isEmpty && (refreshState == .refreshing || isAutoCaching) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textSecondary)
                    Text("Loading articles...")
                        .font(Theme.scaledFont(size: 15))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(articles) { article in
                ArticleRowView(
                    article: article,
                    namespace: namespace,
                    onTap: { handleTap(article) },
                    onToggleRead: { Task { await toggleRead(article) } },
                    onToggleSave: { Task { await toggleSave(article) } },
                    onRefetch: { Task { await refetchArticle(article) } },
                    onDelete: { Task { await deleteArticle(article) } },
                    sourceName: source.isTopicFeed ? article.displayDomain : nil
                )
                .matchedTransitionSource(id: "\(source.id)-\(article.id)", in: transitionNamespace) {
                    $0.clipShape(RoundedRectangle(cornerRadius: 12))
                        .background(Theme.background)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if totalArticleCount > articles.count {
                Button(action: onViewAll) {
                    Text("View all \(totalArticleCount) articles")
                        .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(maxWidth: .infinity)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 15, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

        } header: {
            sectionHeader
                .padding(.bottom, 4)
                .textCase(nil)
        }
        .task {
            let sourceID = source.id
            // Check shared cache first (may already be warm from previous visit)
            if let cached = ThumbnailCache.shared.favicon(for: sourceID) {
                cachedFavicon = cached
            } else {
                let favicon = await Task.detached(priority: .utility) {
                    await PageCacheService.shared.cachedFavicon(for: sourceID)
                }.value
                if let favicon {
                    cachedFavicon = favicon
                    ThumbnailCache.shared.setFavicon(favicon, for: sourceID)
                }
            }
            await loadArticles()
            // Pre-warm row thumbnails for these 5 articles
            await ThumbnailCache.prewarmRowThumbnails(for: articles)
            // Observe article changes reactively instead of polling.
            startArticleObservation()
            // Auto-cache any visible pending/failed articles (e.g. after
            // cache wipe or integrity checker reset) when not refreshing
            if refreshState != .refreshing && !coordinator.isFetching {
                await cacheUncachedArticles()
            }
        }
        .onChange(of: refreshState) { oldValue, newValue in
            // Re-check favicon after refresh completes
            if cachedFavicon == nil && (newValue == .completed || newValue == .idle) {
                Task {
                    let sourceID = source.id
                    let favicon = await Task.detached(priority: .utility) {
                        await PageCacheService.shared.cachedFavicon(for: sourceID)
                    }.value
                    if let favicon {
                        cachedFavicon = favicon
                        ThumbnailCache.shared.setFavicon(favicon, for: sourceID)
                    }
                }
            }
        }
        .onChange(of: coordinator.startupComplete) { _, complete in
            if complete {
                // IntegrityChecker may have reset articles from .cached to
                // .pending — re-cache any that need it (article list updates
                // are handled automatically by the database observation)
                Task {
                    await cacheUncachedArticles()
                }
            }
        }
    }

    // MARK: - Section header

    private var subtitleText: String {
        var parts: [String] = []

        parts.append("\(totalArticleCount) article\(totalArticleCount == 1 ? "" : "s")")

        if let readingText = ReadingTimeFormatter.formatted(minutes: totalReadingMinutes) {
            parts.append("\(readingText) read")
        }

        return parts.joined(separator: " · ")
    }

    private var sectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            faviconView

            VStack(alignment: .leading, spacing: 0) {
                Text(source.title)
                    .font(Theme.scaledFont(size: 18, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(subtitleText)
                        .font(Theme.scaledFont(size: 13, relativeTo: .caption))
                        .foregroundColor(Theme.textPrimary.opacity(0.6))

                    if refreshState == .refreshing || isAutoCaching {
                        refreshSpinner
                    }
                }
            }

            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onViewAll()
        }
        .contextMenu {
            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                onEditName()
            } label: {
                Label("Edit name", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Remove \(source.title)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove source and articles", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all saved articles from this source.")
        }
    }

    // MARK: - Favicon

    @ViewBuilder
    private var faviconView: some View {
        if let favicon = cachedFavicon {
            Image(uiImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            letterAvatar
                .task {
                    let sourceID = source.id
                    for attempt in 0..<5 {
                        if attempt > 0 {
                            try? await Task.sleep(for: .seconds(2))
                        }
                        let favicon = await Task.detached(priority: .utility) {
                            await PageCacheService.shared.cachedFavicon(for: sourceID)
                        }.value
                        if let favicon {
                            cachedFavicon = favicon
                            ThumbnailCache.shared.setFavicon(favicon, for: sourceID)
                            return
                        }
                    }
                }
        }
    }

    private var letterAvatar: some View {
        let letter = String(source.title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.avatarGradient(for: source.title))
                .frame(width: 38, height: 38)
            Text(letter)
                .font(Theme.scaledFont(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Refresh spinner

    private var refreshSpinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
            ZStack {
                Circle()
                    .stroke(Theme.borderProminent, lineWidth: 1.5)
                    .frame(width: 9, height: 9)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accent.opacity(0.6), Theme.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(angle))
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Data loading

    /// Starts a GRDB ValueObservation that reactively updates articles
    /// whenever the database changes, replacing the old 2-second polling loop.
    /// Only shows cached/partial articles on the home screen so pending
    /// articles don't displace readable content during refreshes.
    private func startArticleObservation() {
        let sourceID = source.id
        let cachedStatuses = [ArticleFetchStatus.cached.rawValue,
                              ArticleFetchStatus.partial.rawValue]
        let observation = ValueObservation.tracking { db -> ([Article], Int, Int) in
            let articles = try Article
                .filter(Column("sourceID") == sourceID)
                .filter(cachedStatuses.contains(Column("fetchStatus")))
                .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                .limit(5)
                .fetchAll(db)
            let count = try Article
                .filter(Column("sourceID") == sourceID)
                .filter(cachedStatuses.contains(Column("fetchStatus")))
                .fetchCount(db)
            let readingSum = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(readingMinutes), 0)
                FROM article
                WHERE sourceID = ?
                  AND fetchStatus IN ('cached', 'partial')
            """, arguments: [sourceID]) ?? 0
            return (articles, count, readingSum)
        }
        articleObservation = observation.start(
            in: DatabaseManager.shared.dbPool,
            scheduling: .async(onQueue: .main)
        ) { error in
            // Observation failed — keep existing data
        } onChange: { (newArticles, count, readingSum) in
            articles = newArticles
            let cap = articleLimit > 0 ? articleLimit : 25
            totalArticleCount = min(count, cap)
            totalReadingMinutes = readingSum
        }
    }

    private func loadArticles() async {
        let cachedStatuses = [ArticleFetchStatus.cached.rawValue,
                              ArticleFetchStatus.partial.rawValue]
        do {
            let (loaded, count, readingSum) = try await DatabaseManager.shared.dbPool.read { db in
                let articles = try Article
                    .filter(Column("sourceID") == source.id)
                    .filter(cachedStatuses.contains(Column("fetchStatus")))
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(5)
                    .fetchAll(db)
                let count = try Article
                    .filter(Column("sourceID") == source.id)
                    .filter(cachedStatuses.contains(Column("fetchStatus")))
                    .fetchCount(db)
                let readingSum = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(readingMinutes), 0)
                    FROM article
                    WHERE sourceID = ?
                      AND fetchStatus IN ('cached', 'partial')
                """, arguments: [source.id]) ?? 0
                return (articles, count, readingSum)
            }
            articles = loaded
            let cap = articleLimit > 0 ? articleLimit : 25
            totalArticleCount = min(count, cap)
            totalReadingMinutes = readingSum
        } catch {
            // Keep existing articles
        }
    }

    /// Caches any visible articles that are pending, without requiring a
    /// full refresh. Runs on initial load when no refresh is active
    /// (e.g. after a cache wipe or integrity checker reset).
    private func cacheUncachedArticles() async {
        let uncached = articles.filter { $0.fetchStatus == .pending }
        guard !uncached.isEmpty else { return }

        isAutoCaching = true
        let cacheLevel = source.cacheLevel ?? .standard
        for article in uncached {
            // Bail if a refresh started while we're caching
            guard refreshState != .refreshing, !coordinator.isFetching else { break }
            // Show the row spinner immediately by updating local state
            if let index = articles.firstIndex(where: { $0.id == article.id }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    articles[index].fetchStatus = .fetching
                }
            }
            try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
            // Reconcile local state with DB to ensure we never stay stuck at .fetching
            if let index = articles.firstIndex(where: { $0.id == article.id }),
               articles[index].fetchStatus == .fetching,
               let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
                   try Article.fetchOne(db, key: article.id)
               }) {
                articles[index] = fresh
            }
        }
        isAutoCaching = false
    }

    // MARK: - Article actions

    private func handleTap(_ article: Article) {
        Task {
            let current: Article
            if let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
                try Article.fetchOne(db, key: article.id)
            }) {
                current = fresh
                if let index = articles.firstIndex(where: { $0.id == article.id }) {
                    articles[index] = fresh
                }
            } else {
                current = article
            }

            switch current.fetchStatus {
            case .cached, .partial:
                let hasContent = await PageCacheService.shared.hasCachedContent(for: current)
                if hasContent {
                    markAsReadLocally(current)
                    onOpenArticle(current)
                } else {
                    await fetchArticleInline(current, openOnSuccess: true)
                }
            case .pending:
                await fetchArticleInline(current, openOnSuccess: true)
            case .fetching:
                break
            case .failed:
                break
            }
        }
    }

    private func markAsReadLocally(_ article: Article) {
        guard !article.isRead, let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isRead = true
        let updated = articles[index]
        Task {
            try? await DatabaseManager.shared.dbPool.write { db in
                try updated.update(db)
            }
        }
    }

    private func fetchArticleInline(_ article: Article, openOnSuccess: Bool = false) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            articles[index].fetchStatus = .fetching
        }

        var articleToCache = article
        if articleToCache.etag != nil || articleToCache.lastModified != nil {
            articleToCache.etag = nil
            articleToCache.lastModified = nil
            let snapshot = articleToCache
            try? await DatabaseManager.shared.dbPool.write { db in
                try snapshot.update(db)
            }
        }

        let cacheLevel = source.cacheLevel ?? .standard
        try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel)

        // Always reconcile local state with DB so the spinner never stays stuck
        if let updated = try? await DatabaseManager.shared.dbPool.read({ db in
            try Article.fetchOne(db, key: article.id)
        }) {
            if let index = articles.firstIndex(where: { $0.id == article.id }) {
                articles[index] = updated
            }
            if openOnSuccess,
               updated.fetchStatus == .cached || updated.fetchStatus == .partial {
                markAsReadLocally(updated)
                onOpenArticle(updated)
            }
        }
    }

    private func toggleRead(_ article: Article) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isRead.toggle()
        let updatedArticle = articles[index]
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try updatedArticle.update(db)
            }
        } catch {
            articles[index].isRead.toggle()
        }
    }

    private func toggleSave(_ article: Article) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isSaved.toggle()
        let nowSaved = articles[index].isSaved
        articles[index].savedAt = nowSaved ? Date() : nil
        if nowSaved {
            articles[index].originalSourceName = source.title
            articles[index].originalSourceIconURL = source.iconURL
        } else {
            articles[index].originalSourceName = nil
            articles[index].originalSourceIconURL = nil
        }
        let updatedArticle = articles[index]
        HapticManager.articleCached()
        ToastManager.shared.snack(
            nowSaved ? "Saved" : "Unsaved",
            icon: nowSaved ? "bookmark.fill" : "bookmark.slash"
        )
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try updatedArticle.update(db)
            }
            coordinator.savedArticlesVersion += 1
        } catch {
            articles[index].isSaved.toggle()
            articles[index].savedAt = articles[index].isSaved ? Date() : nil
        }
    }

    private func refetchArticle(_ article: Article) async {
        var article = article
        article.retryCount = 0
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            articles[index].retryCount = 0
            withAnimation(.easeInOut(duration: 0.2)) {
                articles[index].fetchStatus = .fetching
            }
        }
        let cacheLevel = source.cacheLevel ?? .standard
        let articleToCache = article
        try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel, forceReprocess: true)
        // Reconcile local state with DB so the spinner never stays stuck
        let articleID = article.id
        if let index = articles.firstIndex(where: { $0.id == articleID }),
           articles[index].fetchStatus == .fetching,
           let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
               try Article.fetchOne(db, key: articleID)
           }) {
            articles[index] = fresh
        }
    }

    private func deleteArticle(_ article: Article) async {
        HapticManager.deleteConfirm()
        try? await PageCacheService.shared.deleteCachedArticle(article.id)
        do {
            _ = try await DatabaseManager.shared.dbPool.write { db in
                try Article.deleteOne(db, key: article.id)
            }
            withAnimation(Theme.gentleAnimation()) {
                articles.removeAll { $0.id == article.id }
            }
        } catch {
            // Deletion failed silently
        }
    }
}
