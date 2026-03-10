import SwiftUI
import GRDB

private struct ReaderSelection: Identifiable {
    let id = UUID()
    let article: Article
    let source: Source
}

struct SavedSectionView: View {
    let onViewAll: () -> Void

    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Namespace private var namespace
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var articles: [Article] = []
    @State private var readerSelection: ReaderSelection?
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private var preferredScheme: ColorScheme {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemColorScheme
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            if !articles.isEmpty {
                VStack(spacing: 0) {
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
                    }
                }
            }
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
        .sheet(item: $readerSelection) { selection in
            NavigationStack {
                ReaderView(article: selection.article, source: selection.source)
            }
            .toastOverlay()
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(preferredScheme)
        }
    }

    // MARK: - Section header

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            // Bookmark icon
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: [Theme.teal, Theme.teal.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }

            Text("Saved")
                .font(Theme.scaledFont(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: onViewAll) {
                Text("View all")
                    .font(Theme.scaledFont(size: 14, weight: .medium, relativeTo: .subheadline))
                    .foregroundColor(Theme.accent)
            }
        }
    }

    // MARK: - Data loading

    private func loadArticles() async {
        do {
            let loaded = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("isSaved") == true)
                    .order(SQL("COALESCE(savedAt, addedAt)").sqlExpression.desc)
                    .limit(5)
                    .fetchAll(db)
            }
            articles = loaded
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
        let source = try? await DatabaseManager.shared.dbPool.read { db in
            try Source.fetchOne(db, key: article.sourceID)
        }
        guard let source else { return }
        readerSelection = ReaderSelection(article: article, source: source)
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
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                articles[index].fetchStatus = .fetching
            }
        }

        let cacheLevel: CacheLevel
        if let source = try? await DatabaseManager.shared.dbPool.read({ db in
            try Source.fetchOne(db, key: article.sourceID)
        }) {
            cacheLevel = source.cacheLevel ?? .standard
        } else {
            cacheLevel = .standard
        }

        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel, forceReprocess: true)
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
