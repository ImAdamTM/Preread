import SwiftUI
import GRDB

struct SourceSectionView: View {
    let source: Source
    let refreshState: SourceRefreshState
    let onViewAll: () -> Void
    let onRefresh: () -> Void
    let onEditName: () -> Void
    let onRemove: () -> Void

    @ObservedObject private var coordinator = FetchCoordinator.shared
    @Namespace private var namespace
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var articles: [Article] = []
    @State private var cachedFavicon: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var selectedArticle: Article?
    @State private var isAutoCaching = false
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
                            onDelete: { Task { await deleteArticle(article) } }
                        )
                    }
                }
            }
        }
        .task {
            await loadArticles()
            // If a refresh is already in progress when the view appears
            // (e.g. newly added source), start polling immediately
            if refreshState == .refreshing || coordinator.isFetching {
                await pollWhileRefreshing()
            } else {
                // Auto-cache any visible pending/failed articles (e.g. after
                // cache wipe or integrity checker reset)
                await cacheUncachedArticles()
            }
        }
        .onChange(of: refreshState) { oldValue, newValue in
            if newValue == .refreshing {
                // Poll for article updates while this source is refreshing
                // (covers single-source refresh where isFetching isn't set)
                Task { await pollWhileRefreshing() }
            }
            if newValue == .completed || newValue == .idle {
                Task { await loadArticles() }
            }
            // Re-check favicon after refresh completes
            if cachedFavicon == nil && (newValue == .completed || newValue == .idle) {
                Task {
                    let sourceID = source.id
                    let image = await Task.detached(priority: .utility) {
                        await PageCacheService.shared.cachedFavicon(for: sourceID)
                    }.value
                    if let image {
                        cachedFavicon = image
                    }
                }
            }
        }
        .onChange(of: coordinator.isFetching) { oldValue, newValue in
            if newValue {
                // Poll for article updates during bulk refresh
                Task { await pollWhileRefreshing() }
            } else if oldValue {
                // Final reload when fetch cycle completes
                Task { await loadArticles() }
            }
        }
        .onChange(of: coordinator.startupComplete) { _, complete in
            if complete {
                // IntegrityChecker may have reset articles from .cached to
                // .pending — reload and re-cache any that need it
                Task {
                    await loadArticles()
                    await cacheUncachedArticles()
                }
            }
        }
        .sheet(item: $selectedArticle) { article in
            NavigationStack {
                ReaderView(article: article, source: source)
            }
            .toastOverlay()
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(preferredScheme)
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
                        let image = await Task.detached(priority: .utility) {
                            await PageCacheService.shared.cachedFavicon(for: sourceID)
                        }.value
                        if let image {
                            cachedFavicon = image
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

    /// Polls for article changes while a refresh is in progress,
    /// so articles appear on the home screen as they're cached.
    /// Covers both bulk refresh (isFetching) and single-source refresh (refreshState).
    private func pollWhileRefreshing() async {
        while refreshState == .refreshing || coordinator.isFetching {
            try? await Task.sleep(for: .seconds(2))
            guard refreshState == .refreshing || coordinator.isFetching else { break }
            await loadArticles()
        }
    }

    private func loadArticles() async {
        do {
            let loaded = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .filter(Column("fetchStatus") != ArticleFetchStatus.failed.rawValue)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(5)
                    .fetchAll(db)
            }
            articles = loaded
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
            await loadArticles()
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
                    selectedArticle = current
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
        await loadArticles()

        if let updatedIndex = articles.firstIndex(where: { $0.id == article.id }) {
            let updated = articles[updatedIndex]
            if openOnSuccess, updated.fetchStatus == .cached || updated.fetchStatus == .partial {
                markAsReadLocally(updated)
                selectedArticle = updated
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
        let cacheLevel = source.cacheLevel ?? .standard
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
