import SwiftUI
import GRDB

struct SourceSectionView: View {
    let source: Source
    let refreshState: SourceRefreshState
    let onViewAll: () -> Void
    let onRefresh: () -> Void
    let onEditName: () -> Void
    let onRemove: () -> Void
    let onOpenArticle: (Article) -> Void

    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Namespace private var namespace
    @State private var articles: [Article] = []
    @State private var totalArticleCount: Int = 0
    @State private var cachedFavicon: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var isAutoCaching = false
    @State private var articleObservation: AnyDatabaseCancellable?

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
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if totalArticleCount > articles.count {
                Button(action: onViewAll) {
                    Text("View all \(totalArticleCount) articles")
                        .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                        .foregroundColor(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .listRowInsets(EdgeInsets())
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
            let favicon = await Task.detached(priority: .utility) {
                await PageCacheService.shared.cachedFavicon(for: sourceID)
            }.value
            if let favicon {
                cachedFavicon = favicon
            }
            await loadArticles()
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

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            faviconView

            Text(source.title)
                .font(Theme.scaledFont(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)

            if refreshState == .refreshing || isAutoCaching {
                refreshSpinner
            }

            Spacer(minLength: 4)

            Button(action: onViewAll) {
                Text("View all")
                    .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundColor(Theme.accent)
            }
        }
        .contentShape(Rectangle())
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
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))
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
                            return
                        }
                    }
                }
        }
    }

    private var letterAvatar: some View {
        let letter = String(source.title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.avatarGradient(for: source.title))
                .frame(width: 32, height: 32)
            Text(letter)
                .font(Theme.scaledFont(size: 15, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Refresh spinner

    private var refreshSpinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
            ZStack {
                Circle()
                    .stroke(Theme.borderProminent, lineWidth: 2)
                    .frame(width: 16, height: 16)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accent.opacity(0.6), Theme.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(angle))
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Data loading

    /// Starts a GRDB ValueObservation that reactively updates articles
    /// whenever the database changes, replacing the old 2-second polling loop.
    private func startArticleObservation() {
        let sourceID = source.id
        let observation = ValueObservation.tracking { db -> ([Article], Int) in
            let articles = try Article
                .filter(Column("sourceID") == sourceID)
                .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                .limit(5)
                .fetchAll(db)
            let count = try Article
                .filter(Column("sourceID") == sourceID)
                .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                .fetchCount(db)
            return (articles, count)
        }
        articleObservation = observation.start(
            in: DatabaseManager.shared.dbPool,
            scheduling: .async(onQueue: .main)
        ) { error in
            // Observation failed — keep existing data
        } onChange: { (newArticles, count) in
            articles = newArticles
            totalArticleCount = count
        }
    }

    private func loadArticles() async {
        do {
            let (loaded, count) = try await DatabaseManager.shared.dbPool.read { db in
                let articles = try Article
                    .filter(Column("sourceID") == source.id)
                    .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(5)
                    .fetchAll(db)
                let count = try Article
                    .filter(Column("sourceID") == source.id)
                    .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                    .fetchCount(db)
                return (articles, count)
            }
            articles = loaded
            totalArticleCount = count
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
            try? await DatabaseManager.shared.dbPool.write { db in
                try articleToCache.update(db)
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
        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel, forceReprocess: true)
        // Reconcile local state with DB so the spinner never stays stuck
        if let index = articles.firstIndex(where: { $0.id == article.id }),
           articles[index].fetchStatus == .fetching,
           let fresh = try? await DatabaseManager.shared.dbPool.read({ db in
               try Article.fetchOne(db, key: article.id)
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
