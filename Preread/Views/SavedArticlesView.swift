import SwiftUI
import GRDB

struct SavedArticlesView: View {
    @Namespace private var namespace
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var detailCoordinator = ArticleDetailCoordinator.shared
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    @State private var articles: [Article] = []
    @State private var sourceNames: [UUID: String] = [:]
    @State private var searchText = ""
    @State private var readerSelection: ReaderSelection?
    @State private var transitionSourceID: String?
    @State private var failedArticle: Article?
    @State private var isLoading = true
    @State private var heroTitleMinY: CGFloat = 200
    @State private var tealGradientImage: UIImage?

    private var preferredScheme: ColorScheme {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemColorScheme
        }
    }

    private var filteredArticles: [Article] {
        if searchText.isEmpty { return articles }
        return articles.filter { article in
            if article.title.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            let name = article.originalSourceName ?? sourceNames[article.sourceID]
            if let name, name.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            return false
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .padding(.top, 80)
            } else if articles.isEmpty {
                emptyState
            } else {
                articleList
            }
        }
        .toolbarBackground(navBarBackgroundOpacity > 0.5 ? .visible : .hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.teal)
                    Text("Saved Articles")
                        .font(Theme.scaledFont(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                .opacity(navBarTitleOpacity)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.textPrimary)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search saved articles")
        .task {
            await loadArticles()
            await ThumbnailCache.prewarmRowThumbnails(for: articles)
            isLoading = false
            // If any articles are still pending/fetching, poll until they settle
            await pollWhileCaching()
        }
        .sheet(item: $failedArticle) { article in
            FailedArticleSheet(
                article: article,
                onRetry: {
                    Task { await refetchArticle(article) }
                },
                onRemove: {
                    Task { await deleteArticle(article) }
                }
            )
        }
        .sheet(item: $readerSelection) { selection in
            NavigationStack {
                ReaderView(article: selection.article, source: selection.source)
            }
            .navigationTransition(.zoom(sourceID: transitionSourceID ?? "row-\(selection.article.id)", in: namespace))
            .toastOverlay()
            .presentationDragIndicator(.hidden)
            .preferredColorScheme(preferredScheme)
        }
    }

    // MARK: - Article list

    private var articleList: some View {
        List {
            // Hero section
            heroRow
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .zIndex(-1)

            // Saved articles carousel
            SavedCarouselView(
                transitionNamespace: namespace,
                onOpenArticle: { article in
                    markAsReadLocally(article)
                    transitionSourceID = "saved-carousel-\(article.id)"
                    Task { await openArticle(article) }
                }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Text("All articles")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(Theme.textPrimary)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(filteredArticles) { article in
                ArticleRowView(
                    article: article,
                    namespace: namespace,
                    onTap: { transitionSourceID = "row-\(article.id)"; handleTap(article) },
                    onToggleRead: { Task { await toggleRead(article) } },
                    onToggleSave: { Task { await unsaveArticle(article) } },
                    onRefetch: { Task { await refetchArticle(article) } },
                    onDelete: { Task { await deleteArticle(article) } },
                    sourceName: article.originalSourceName ?? sourceNames[article.sourceID],
                    showUnsaveInsteadOfSave: true
                )
                .matchedTransitionSource(id: "row-\(article.id)", in: namespace) {
                    $0.clipShape(RoundedRectangle(cornerRadius: 12))
                        .background(Theme.background)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if filteredArticles.isEmpty {
                noResultsRow
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Nav bar opacity

    private var navBarTitleOpacity: Double {
        let startFade: CGFloat = 70
        let fullyVisible: CGFloat = 9
        if Theme.reduceMotion {
            return heroTitleMinY < 40 ? 1 : 0
        }
        if heroTitleMinY > startFade { return 0 }
        if heroTitleMinY < fullyVisible { return 1 }
        return Double(1 - (heroTitleMinY - fullyVisible) / (startFade - fullyVisible))
    }

    private var navBarBackgroundOpacity: Double {
        let startFade: CGFloat = 80
        let fullyOpaque: CGFloat = 9
        if Theme.reduceMotion {
            return heroTitleMinY < 50 ? 1 : 0
        }
        if heroTitleMinY > startFade { return 0 }
        if heroTitleMinY < fullyOpaque { return 1 }
        return Double(1 - (heroTitleMinY - fullyOpaque) / (startFade - fullyOpaque))
    }

    // MARK: - Hero

    private var heroRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Saved icon
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: -2) {
                Text("Saved Articles")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Theme.textPrimary)
                    .modifier(HeroTitleScrollTracker { minY in
                        heroTitleMinY = minY
                    })

                Text("\(articles.count) article\(articles.count == 1 ? "" : "s")")
                    .font(Theme.scaledFont(size: 13, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.6))
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(alignment: .top) {
            blurredTealBackground
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Blurred background (matches SourceHeroView pattern)

    private var blurredTealBackground: some View {
        ZStack {
            if let img = tealGradientImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .clipped()
            } else {
                Color.clear
                    .task {
                        tealGradientImage = Self.makeTealGradientImage()
                    }
            }
        }
        .opacity(0.3)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.4),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private static func makeTealGradientImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cgColors = [UIColor(Theme.teal).cgColor, UIColor(Theme.teal.opacity(0.5)).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors as CFArray, locations: [0, 0.5]) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bookmark")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Theme.textSecondary)
            Text("No saved articles")
                .font(Theme.scaledFont(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Swipe right on any article to save it for later.")
                .font(Theme.scaledFont(size: 14, relativeTo: .subheadline))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - No search results

    private var noResultsRow: some View {
        VStack(spacing: 8) {
            Text("No results")
                .font(Theme.scaledFont(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Try a different search term.")
                .font(Theme.scaledFont(size: 14, relativeTo: .subheadline))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Data loading

    private func loadArticles() async {
        do {
            let loaded = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("isSaved") == true)
                    .order(Column("savedAt").desc, Column("addedAt").desc)
                    .fetchAll(db)
            }
            articles = loaded

            // Load source names for attribution
            let sourceIDs = Set(loaded.map(\.sourceID))
            var names: [UUID: String] = [:]
            for sourceID in sourceIDs {
                if let source = try? await DatabaseManager.shared.dbPool.read({ db in
                    try Source.fetchOne(db, key: sourceID)
                }) {
                    names[sourceID] = source.title
                }
            }
            sourceNames = names
        } catch {
            // Silently fail
        }
    }

    private func pollWhileCaching() async {
        while articles.contains(where: { $0.fetchStatus == .pending || $0.fetchStatus == .fetching }) {
            try? await Task.sleep(for: .seconds(1))
            await loadArticles()
        }
    }

    // MARK: - Actions

    private func handleTap(_ article: Article) {
        Task {
            // Re-read from DB for freshness
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
                let hasCachedContent = await PageCacheService.shared.hasCachedContent(for: current)
                if hasCachedContent {
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
                failedArticle = current
            }
        }
    }

    private func openArticle(_ article: Article) async {
        // Load the source for ReaderView
        let source = try? await DatabaseManager.shared.dbPool.read { db in
            try Source.fetchOne(db, key: article.sourceID)
        }
        guard let source else { return }
        let selection = ReaderSelection(article: article, source: source)
        if detailCoordinator.isSplitView {
            detailCoordinator.selection = selection
        } else {
            readerSelection = selection
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

        // Look up source's cache level
        let source = try? await DatabaseManager.shared.dbPool.read { db in
            try Source.fetchOne(db, key: article.sourceID)
        }
        let cacheLevel = source?.effectiveCacheLevel ?? .standard

        try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
        await loadArticles()

        if let updatedIndex = articles.firstIndex(where: { $0.id == article.id }) {
            let updated = articles[updatedIndex]
            if updated.fetchStatus == .failed {
                failedArticle = updated
            } else if openOnSuccess, updated.fetchStatus == .cached || updated.fetchStatus == .partial {
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

    private func unsaveArticle(_ article: Article) async {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        let isSavedPage = article.sourceID == Source.savedPagesID
        HapticManager.articleCached()
        ToastManager.shared.snack("Removed from Saved", icon: "bookmark.slash")

        // Remove from the array immediately so the swipe collapse animation
        // can run. The DB write happens in the background afterward.
        withAnimation(Theme.gentleAnimation()) {
            articles.removeAll { $0.id == article.id }
        }

        if isSavedPage {
            // Saved-pages articles have no feed source — delete entirely
            try? await PageCacheService.shared.deleteCachedArticle(article.id)
            _ = try? await DatabaseManager.shared.dbPool.write { db in
                try Article.deleteOne(db, key: article.id)
            }
        } else {
            // Feed articles: just un-flag, keep the article in its source
            var updated = article
            updated.isSaved = false
            updated.savedAt = nil
            updated.originalSourceName = nil
            updated.originalSourceIconURL = nil
            let articleToUpdate = updated
            do {
                try await DatabaseManager.shared.dbPool.write { db in
                    try articleToUpdate.update(db)
                }
            } catch {
                // DB write failed — re-insert the article
                withAnimation(Theme.gentleAnimation()) {
                    articles.insert(article, at: min(index, articles.count))
                }
            }
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
        let source = try? await DatabaseManager.shared.dbPool.read { db in
            try Source.fetchOne(db, key: articleToCache.sourceID)
        }
        let cacheLevel = source?.effectiveCacheLevel ?? .standard
        try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel, forceReprocess: true)
        await loadArticles()
    }

    private func deleteArticle(_ article: Article) async {
        HapticManager.deleteConfirm()

        // Remove from the array immediately so the row collapse animation runs
        withAnimation(Theme.gentleAnimation()) {
            articles.removeAll { $0.id == article.id }
        }

        // Clean up cached data and DB record in the background
        try? await PageCacheService.shared.deleteCachedArticle(article.id)
        _ = try? await DatabaseManager.shared.dbPool.write { db in
            try Article.deleteOne(db, key: article.id)
        }
    }
}
