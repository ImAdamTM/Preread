import SwiftUI
import GRDB

struct SavedSectionView: View {
    var transitionNamespace: Namespace.ID
    let onViewAll: () -> Void
    let onOpenArticle: (Article) -> Void

    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Namespace private var namespace
    @State private var articles: [Article] = []
    @State private var totalSavedCount: Int = 0

    var body: some View {
        Section {
            ForEach(articles) { article in
                ArticleRowView(
                    article: article,
                    namespace: namespace,
                    onTap: { handleTap(article) },
                    onToggleRead: { Task { await toggleRead(article) } },
                    onToggleSave: { Task { await toggleSave(article) } },
                    onRefetch: { Task { await refetchArticle(article) } },
                    onDelete: { Task { await deleteArticle(article) } },
                    sourceName: article.originalSourceName,
                    showUnsaveInsteadOfSave: true
                )
                .matchedTransitionSource(id: "saved-section-\(article.id)", in: transitionNamespace) {
                    $0.clipShape(RoundedRectangle(cornerRadius: 12))
                        .background(Theme.background)
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
            await loadArticles()
        }
        .onChange(of: coordinator.isFetching) { oldValue, newValue in
            if !newValue && oldValue {
                Task { await loadArticles() }
            }
        }
        .onChange(of: coordinator.startupComplete) { _, complete in
            if complete {
                Task { await loadArticles() }
            }
        }
        .onChange(of: coordinator.savedArticlesVersion) { _, _ in
            Task { await loadArticles() }
        }
    }

    // MARK: - Section header

    private var subtitleText: String {
        if totalSavedCount > articles.count {
            return "Latest \(articles.count) · \(totalSavedCount) articles"
        }
        return "\(totalSavedCount) article\(totalSavedCount == 1 ? "" : "s")"
    }

    private var sectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Bookmark icon
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [Theme.teal, Theme.teal.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "bookmark.fill")
                    .font(Theme.scaledFont(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: -2) {
                Text("Saved")
                    .font(Theme.scaledFont(size: 20, weight: .regular))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(Theme.scaledFont(size: 13, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.6))
            }

            Spacer(minLength: 4)

            Button(action: onViewAll) {
                Text("View all")
                    .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.accentGradient)
            }
        }
    }

    // MARK: - Data loading

    private func loadArticles() async {
        do {
            let (loaded, count) = try await DatabaseManager.shared.dbPool.read { db in
                let articles = try Article
                    .filter(Column("isSaved") == true)
                    .order(SQL("COALESCE(savedAt, addedAt)").sqlExpression.desc)
                    .limit(5)
                    .fetchAll(db)
                let count = try Article
                    .filter(Column("isSaved") == true)
                    .fetchCount(db)
                return (articles, count)
            }
            articles = loaded
            totalSavedCount = count
        } catch {
            // Keep existing articles
        }
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
                    await openArticle(current)
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

    private func openArticle(_ article: Article) async {
        onOpenArticle(article)
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

        // Look up the source's cache level
        let cacheLevel: CacheLevel
        if let source = try? await DatabaseManager.shared.dbPool.read({ db in
            try Source.fetchOne(db, key: article.sourceID)
        }) {
            cacheLevel = source.cacheLevel ?? .standard
        } else {
            cacheLevel = .standard
        }

        try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel)
        await loadArticles()

        if let updatedIndex = articles.firstIndex(where: { $0.id == article.id }) {
            let updated = articles[updatedIndex]
            if openOnSuccess, updated.fetchStatus == .cached || updated.fetchStatus == .partial {
                markAsReadLocally(updated)
                await openArticle(updated)
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
            if !nowSaved {
                // Reload to remove the unsaved article from the list
                await loadArticles()
            }
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

        let articleToCache = article
        // Manually saved pages (no feed source) remember the cache level the
        // user chose when saving. Feed articles use the source's current level.
        let cacheLevel: CacheLevel
        if articleToCache.sourceID == Source.savedPagesID,
           let existing = try? await DatabaseManager.shared.dbPool.read({ db in
               try CachedPage.fetchOne(db, key: articleToCache.id)
           }) {
            cacheLevel = existing.cacheLevelUsed
        } else {
            let source = try? await DatabaseManager.shared.dbPool.read { db in
                try Source.fetchOne(db, key: articleToCache.sourceID)
            }
            cacheLevel = source?.effectiveCacheLevel ?? .standard
        }

        try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel, forceReprocess: true)
        await loadArticles()
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
